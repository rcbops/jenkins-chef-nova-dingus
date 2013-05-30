#!/usr/bin/env bash


START_TIME=$(date +%s)
INSTANCE_IMAGE=${INSTANCE_IMAGE:-jenkins-precise}
PACKAGE_COMPONENT=${PACKAGE_COMPONENT:-grizzly}

source $(dirname $0)/chef-jenkins.sh

print_banner "Initializing Job"
init

CHEF_ENV="bigcluster"
print_banner "Build Parameters
~~~~~~~~~~~~~~~~
environment = ${CHEF_ENV}
INSTANCE_IMAGE=${INSTANCE_IMAGE}
AVAILABILITY_ZONE=${AZ}
TMPDIR = ${TMPDIR}
GIT_PATCH_URL = ${GIT_PATCH_URL}
GIT_MASTER_URL = ${GIT_MASTER_URL}
We are building for ${PACKAGE_COMPONENT}"

rm -rf logs
mkdir -p logs/run
exec 9>logs/run/out.log
BASH_XTRACEFD=9
set -x

declare -a cluster
cluster=(api api2 compute1 compute2)

start_timer
print_banner "creating chef server"
boot_and_wait chef-server
wait_for_ssh chef-server
stop_timer

start_timer
x_with_server "Uploading cookbooks and booting the cluster" "chef-server" <<EOF
set_package_provider
update_package_provider
flush_iptables
run_twice install_package git-core
start_chef_services
rabbitmq_fixup
chef_fixup
run_twice checkout_cookbooks
run_twice upload_cookbooks
run_twice upload_roles
EOF
background_task "fc_do"
stop_timer

start_timer
boot_cluster ${cluster[@]}
stop_timer

start_timer
print_banner "Waiting for IP connectivity to the instances"
wait_for_cluster_ssh ${cluster[@]}
print_banner "Waiting for SSH to become available"
wait_for_cluster_ssh_key ${cluster[@]}
stop_timer

start_timer
x_with_cluster "Cluster booted.  Setting up the VPN thing." ${cluster[@]} <<EOF
wait_for_rhn
set_package_provider
update_package_provider
run_twice install_package bridge-utils
EOF
setup_private_network eth0 br99 api ${cluster[@]}
stop_timer

start_timer
print_banner "Setting up the chef environment"
# at this point, chef server is done, cluster is up.
# let's set up the environment.
create_chef_environment chef-server ${CHEF_ENV}
# Set the package_component environment variable (not really needed in grizzly but no matter)
knife_set_package_component chef-server ${CHEF_ENV} ${PACKAGE_COMPONENT}

# Define vrrp ips
api_vrrp_ip=$(ip_for_host api | awk 'BEGIN{FS="."};{print "10.127.54."$4}')
db_vrrp_ip=$(ip_for_host api2 | awk 'BEGIN{FS="."};{print "10.127.54."$4}')
rabbitmq_vrrp_ip=$(ip_for_host compute1 | awk 'BEGIN{FS="."};{print "10.127.54."$4}')
print_banner "VRRP configuration:
API   : ${api_vrrp_ip}
DB    : ${db_vrrp_ip}
RABBIT: ${rabbitmq_vrrp_ip}"

# add the lb service vips to the environment
knife exec -E "@e=Chef::Environment.load('${CHEF_ENV}'); a=@e.override_attributes; \
a['vips']['horizon-dash_ssl']='${api_vrrp_ip}';
a['vips']['horizon-dash']='${api_vrrp_ip}';
a['vips']['nova-api']='${api_vrrp_ip}';
a['vips']['nova-ec2-public']='${api_vrrp_ip}';
a['vips']['nova-novnc-proxy']='${api_vrrp_ip}';
a['vips']['nova-xvpvnc-proxy']='${api_vrrp_ip}';
a['vips']['keystone-service-api']='${api_vrrp_ip}';
a['vips']['keystone-admin-api']='${api_vrrp_ip}';
a['vips']['cinder-api']='${api_vrrp_ip}';
a['vips']['glance-api']='${api_vrrp_ip}';
a['vips']['glance-registry']='${api_vrrp_ip}';
a['vips']['swift-proxy']='${api_vrrp_ip}';
a['vips']['rabbitmq-queue']='${rabbitmq_vrrp_ip}';
a['vips']['mysql-db']='${db_vrrp_ip}';
@e.override_attributes(a); @e.save" -c ${TMPDIR}/chef/chef-server/knife.rb

# Disable glance image_uploading
set_environment_attribute chef-server ${CHEF_ENV} "override_attributes/glance/image_upload" "false"

# add the clients to the chef server
add_chef_clients chef-server ${cluster[@]}
stop_timer

start_timer
x_with_cluster "Installing chef-client and running for the first time" ${cluster[@]} <<EOF
flush_iptables
install_chef_client
fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client
EOF
stop_timer


# fix up api node with a cinder-volumes vg
start_timer
x_with_cluster "setting up cinder-volumes vg on api node for cinder" api <<EOF
install_package lvm2
umount /mnt
pvcreate /dev/vdb
vgcreate cinder-volumes /dev/vdb
EOF
stop_timer

start_timer
role_add chef-server api "role[ha-controller1],role[cinder-volume]"
x_with_cluster "Installing first controller" api <<EOF
chef-client
EOF
stop_timer

start_timer
role_add chef-server api2 "role[ha-controller2]"
x_with_cluster "Installing second controller" api2 <<EOF
chef-client
EOF
stop_timer

start_timer
set_environment_attribute chef-server ${CHEF_ENV} "override_attributes/glance/image_upload" "true"
role_add chef-server api "recipe[kong],recipe[exerstack]"
x_with_cluster "Finalizing api" api <<EOF
chef-client
EOF
stop_timer

role_add chef-server compute1 "role[single-compute]"
role_add chef-server compute2 "role[single-compute]"

start_timer
# run the proxy to generate the ring, now that we
# have discovered disks (ephemeral0)
x_with_cluster "Running chef on all nodes" ${cluster[@]} <<EOF
chef-client
EOF
stop_timer

start_timer
x_with_server "Fixerating the API nodes" api <<EOF
fix_for_tests
EOF
background_task "fc_do"
collect_tasks
stop_timer

retval=0

# setup test list
declare -a testlist=(cinder nova glance swift keystone glance-swift)

start_timer
# run tests
if ( ! run_tests api ${PACKAGE_COMPONENT} ${testlist[@]} ); then
    echo "Tests failed."
    retval=1
fi
stop_timer

start_timer
x_with_cluster "Fixing log perms" ${cluster[@]}  <<EOF
if [ -e /var/log/nova ]; then chmod 755 /var/log/nova; fi
if [ -e /var/log/keystone ]; then chmod 755 /var/log/keystone; fi
if [ -e /var/log/apache2 ]; then chmod 755 /var/log/apache2; fi
if [ -e /var/log ]; then chmod 755 /var/log; fi
if [ -e /etc/nova ]; then chmod -R 755 /etc/nova; fi
if [ -e /etc/keystone ]; then chmod -R 755 /etc/keystone; fi
if [ -e /etc/glance ]; then chmod -R 755 /etc/glance; fi
if [ -e /etc/cinder ]; then chmod -R 755 /etc/cinder; fi
if [ -e /etc/swift ]; then chmod -R 755 /etc/swift; fi
EOF

cluster_fetch_file "/var/log/{nova,glance,keystone,apache2}/*log" ./logs ${cluster[@]}
cluster_fetch_file "/var/log/syslog" ./logs ${cluster[@]}
cluster_fetch_file "/etc/{nova,glance,keystone,cinder,swift}/*" ./logs/config ${cluster[@]}
stop_timer

#if [ $retval -eq 0 ]; then
#    if [ -n "${GIT_COMMENT_URL}" ] && [ "${GIT_COMMENT_URL}" != "noop" ] ; then
#        github_post_comment ${GIT_COMMENT_URL} "Gate:  Nova AIO (${INSTANCE_IMAGE})\n * ${BUILD_URL}consoleFull : SUCCESS"
#    else
#        echo "skipping building comment"
##    fi
#fi

END_TIME=$(date +%s)
print_banner "Total time taken was approx $(( (END_TIME-START_TIME)/60 )) minutes"
exit $retval
