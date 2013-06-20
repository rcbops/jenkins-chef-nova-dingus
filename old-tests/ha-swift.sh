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
cluster=(cont1 cont2 storage1 storage2 storage3)

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

print_banner "Setting up the chef environment"
# at this point, chef server is done, cluster is up.
# let's set up the environment.
create_chef_environment chef-server ${CHEF_ENV}
# Set the package_component environment variable
knife_set_package_component chef-server ${CHEF_ENV} ${PACKAGE_COMPONENT}

# Define vrrp ips
api_vrrp_ip=$(ip_for_host storage1 | awk 'BEGIN{FS="."};{print "10.127.54."$4}')
db_vrrp_ip=$(ip_for_host storage2 | awk 'BEGIN{FS="."};{print "10.127.54."$4}')
print_banner "VRRP configuration:
API   : ${api_vrrp_ip}
DB    : ${db_vrrp_ip}"

# add the lb service vips and cloudfiles settings to the environment
knife exec -E "@e=Chef::Environment.load('${CHEF_ENV}'); a=@e.override_attributes; \
a['vips']['keystone-service-api']='${api_vrrp_ip}';
a['vips']['keystone-admin-api']='${api_vrrp_ip}';
a['vips']['mysql-db']='${db_vrrp_ip}';
a['vips']['swift-proxy']='${api_vrrp_ip}';
@e.override_attributes(a); @e.save" -c ${TMPDIR}/chef/chef-server/knife.rb

# add the clients to the chef server
add_chef_clients chef-server ${cluster[@]}

# fix up extra disk on storage nodes
x_with_cluster "un-fscking ephemerals" storage1 storage2 storage3 <<EOF
umount /mnt
dd if=/dev/zero of=/dev/vdb bs=1024 count=1024
grep -v "/mnt" /etc/fstab > /tmp/newfstab
cp /tmp/newfstab /etc/fstab
EOF

x_with_cluster "Installing chef-client and running for the first time" ${cluster[@]} <<EOF
flush_iptables
install_chef_client
fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client
EOF

role_add chef-server cont1 "role[ha-swift-controller1]"
x_with_cluster "Installing cont1" cont1 <<EOF
chef-client
EOF

role_add chef-server cont2 "role[ha-swift-controller2]"
x_with_cluster "Installing cont2" cont2 <<EOF
chef-client
EOF

x_with_cluster "Finalising mysql replication on cont1" cont1 <<EOF
chef-client
EOF

for node_no in {1..3}; do
    role_add chef-server storage${node_no} "role[swift-object-server],role[swift-container-server],role[swift-account-server]"
    set_node_attribute chef-server storage${node_no} "normal/swift" "{\"zone\": ${node_no} }"
done

x_with_cluster "Running chef on Storage nodes - Pass 1" storage{1..3}  <<EOF
chef-client
EOF

# run on cont1 to generate the ring, now that we
# have discovered disks (ephemeral0)
x_with_cluster "Running on cont1 to generate the ring" cont1  <<EOF
chef-client
EOF

# Now run all the storage servers
x_with_cluster "Running chef on Storage nodes - Pass 2" storage{1..3} <<EOF
chef-client
EOF

role_add chef-server cont1 "recipe[kong],recipe[exerstack]"

# all nodes - pull the ring
x_with_cluster "All nodes - pass 1" ${cluster[@]} <<EOF
chef-client
EOF

# all nodes - pull the ring
x_with_cluster "All nodes - pass 2" ${cluster[@]} <<EOF
chef-client
EOF

x_with_cluster "Fixerating the cont1 node" cont1 <<EOF
fix_for_tests
EOF
background_task "fc_do"
collect_tasks

retval=0

# setup test list
declare -a testlist=(swift)

print_banner "running tests with all services on cont1"
# run tests
if ( ! run_tests cont1 ${PACKAGE_COMPONENT} ${testlist[@]} ); then
    echo "Tests failed."
    retval=1
fi

x_with_cluster "Fixing log perms" cont1 cont2 storage{1..3}  <<EOF
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
