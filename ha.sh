#!/usr/bin/env bash


START_TIME=$(date +%s)
INSTANCE_IMAGE=${INSTANCE_IMAGE:-jenkins-precise}
PACKAGE_COMPONENT=${PACKAGE_COMPONENT:-folsom}

source $(dirname $0)/chef-jenkins.sh
source $(dirname $0)/files/cloudfiles-credentials

print_banner "Initializing Job"
init

CHEF_ENV="ha"
print_banner "Build Parameters
~~~~~~~~~~~~~~~~
environment = ${CHEF_ENV}
INSTANCE_IMAGE=${INSTANCE_IMAGE}
AVAILABILITY_ZONE=${AZ}
TMPDIR = ${TMPDIR}
GIT_PATCH_URL = ${GIT_PATCH_URL}
We are building for ${PACKAGE_COMPONENT}"

rm -rf logs
mkdir -p logs/run
exec 9>logs/run/out.log
BASH_XTRACEFD=9
set -x

declare -a cluster
cluster=(cont1 cont2 compute1 compute2)

print_banner "creating chef server"
boot_and_wait chef-server
wait_for_ssh chef-server

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

boot_cluster ${cluster[@]}

print_banner "Waiting for IP connectivity to the instances"
wait_for_cluster_ssh ${cluster[@]}
print_banner "Waiting for SSH to become available"
wait_for_cluster_ssh_key ${cluster[@]}

x_with_cluster "Cluster booted.  Setting up the VPN thing." ${cluster[@]} <<EOF
wait_for_rhn
set_package_provider
update_package_provider
run_twice install_package bridge-utils
EOF

print_banner "setting up private network"
setup_private_network eth0 br99 cont1 ${cluster[@]}

print_banner "Setting up the chef environment"
# at this point, chef server is done, cluster is up.
# let's set up the environment.
create_chef_environment chef-server ${CHEF_ENV}
# Set the package_component environment variable
knife_set_package_component chef-server ${CHEF_ENV} ${PACKAGE_COMPONENT}

# Define vrrp ips
api_vrrp_ip=$(ip_for_host compute1 | awk 'BEGIN{FS="."};{print "10.127.54."$4}')
db_vrrp_ip=$(ip_for_host compute2 | awk 'BEGIN{FS="."};{print "10.127.54."$4}')
rabbitmq_vrrp_ip=$(ip_for_host cont2 | awk 'BEGIN{FS="."};{print "10.127.54."$4}')
print_banner "VRRP configuration:
API   : ${api_vrrp_ip}
DB    : ${db_vrrp_ip}
RABBIT: ${rabbitmq_vrrp_ip}"

# add the lb service vips and cloudfiles settings to the environment
knife exec -E "@e=Chef::Environment.load('${CHEF_ENV}'); a=@e.override_attributes; \
a['vips']['rabbitmq-queue']='${rabbitmq_vrrp_ip}';
a['vips']['glance-registry']='${api_vrrp_ip}';
a['vips']['keystone-service-api']='${api_vrrp_ip}';
a['vips']['nova-novnc-proxy']='${api_vrrp_ip}';
a['vips']['keystone-admin-api']='${api_vrrp_ip}';
a['vips']['glance-api']='${api_vrrp_ip}';
a['vips']['mysql-db']='${db_vrrp_ip}';
a['vips']['nova-api']='${api_vrrp_ip}';
a['vips']['nova-ec2-public']='${api_vrrp_ip}';
a['vips']['cinder-api']='${api_vrrp_ip}';
a['vips']['horizon-dash']='${api_vrrp_ip}';
a['vips']['horizon-dash_ssl']='${api_vrrp_ip}';
a['vips']['nova-xvpvnc-proxy']='${api_vrrp_ip}';
a['glance']['image_upload']=false;
a['glance']['api']['default_store']='swift';
a['glance']['api']['swift_store_user']='${ST_USER}';
a['glance']['api']['swift_store_key']='${ST_KEY}';
a['glance']['api']['swift_store_auth_version']='${ST_AUTH_VERSION}';
a['glance']['api']['swift_store_auth_address']='${ST_AUTH}';
a['glance']['api']['swift_store_region']='DFW';
@e.override_attributes(a); @e.save" -c ${TMPDIR}/chef/chef-server/knife.rb

# Disable glance image_uploading
set_environment_attribute chef-server ${CHEF_ENV} "override_attributes/glance/image_upload" "false"

# add the clients to the chef server
add_chef_clients chef-server ${cluster[@]}

# nodes to prep with base and build-essentials.
#prep_list=(cont1 cont2 compute1 compute2)
#for d in "${prep_list[@]}"; do
#    background_task role_add chef-server ${d} "role[base],recipe[build-essential]"
#done

x_with_cluster "Installing chef-client and running for the first time" ${cluster[@]} <<EOF
flush_iptables
install_chef_client
fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client
EOF

# fix up controller nodes with a cinder-volumes vg
if [ ${PACKAGE_COMPONENT} = "folsom" ]; then
x_with_cluster "setting up cinder-volumes vg on controller nodes for cinder" cont1 cont2 <<EOF
install_package lvm2
umount /mnt
pvcreate /dev/vdb
vgcreate cinder-volumes /dev/vdb
EOF
fi

role_add chef-server cont1 "role[ha-controller1],role[cinder-volume]"
x_with_cluster "Installing cont1" cont1 <<EOF
chef-client
EOF

role_add chef-server cont2 "role[ha-controller2],role[cinder-volume]"
x_with_cluster "Installing cont2" cont2 <<EOF
chef-client
EOF

x_with_cluster "Finalising mysql replication on cont1" cont1 <<EOF
chef-client
EOF

role_add chef-server compute1 "role[single-compute]"
role_add chef-server compute2 "role[single-compute]"

role_add chef-server cont1 "recipe[kong],recipe[exerstack]"

# turn on glance uploads again
set_environment_attribute chef-server ${CHEF_ENV} "override_attributes/glance/image_upload" "true"

# this sucks - but we need to do it because we can't do glance image upload on two nodes at the same time
x_with_cluster "Glance Image Upload" cont1 <<EOF
chef-client
EOF

# all nodes, just for good measure.
x_with_cluster "All nodes" ${cluster[@]} <<EOF
chef-client
EOF

x_with_cluster "Fixerating the cont1 node" cont1 <<EOF
fix_for_tests
EOF
background_task "fc_do"
collect_tasks

retval=0

# setup test list
declare -a testlist=(nova glance keystone glance-swift)
if [ ${PACKAGE_COMPONENT} = "folsom" ]; then
    testlist=("cinder" "${testlist[@]}")
fi

print_banner "running tests with all services on cont1"
# run tests
if ( ! run_tests cont1 ${PACKAGE_COMPONENT} ${testlist[@]} ); then
    echo "Tests failed."
    retval=1
fi

real_cont1_hostname=$(hostname_for_host cont1)
print_banner "rebooting cont1 with hostname ${real_cont1_hostname} "
nova reboot ${real_cont1_hostname}
print_banner "waiting for cont1 to come back"
wait_for_ssh cont1
print_banner "setting up privatenet again on cont1"
setup_private_network eth0 br99 cont1 cont1

print_banner "running tests with all services on cont2"
# run tests
if ( ! run_tests cont1 ${PACKAGE_COMPONENT} ${testlist[@]} ); then
    echo "Tests failed."
    retval=1
fi

x_with_cluster "Fixing log perms" cont1 cont2 compute1 compute2  <<EOF
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

#if [ $retval -eq 0 ]; then
#    if [ -n "${GIT_COMMENT_URL}" ] && [ "${GIT_COMMENT_URL}" != "noop" ] ; then
#        github_post_comment ${GIT_COMMENT_URL} "Gate:  Nova AIO (${INSTANCE_IMAGE})\n * ${BUILD_URL}consoleFull : SUCCESS"
#    else
#        echo "skipping building comment"
#    fi
#fi

END_TIME=$(date +%s)
print_banner "Total time taken was approx $(( (END_TIME-START_TIME)/60 )) minutes"
exit $retval
