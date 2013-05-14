#!/usr/bin/env bash


START_TIME=$(date +%s)
INSTANCE_IMAGE=${INSTANCE_IMAGE:-jenkins-precise}
PACKAGE_COMPONENT=${PACKAGE_COMPONENT:-essex-final}

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
cluster=(mysql keystone glance api api2 horizon compute1 compute2 proxy storage1 storage2 storage3)

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
setup_private_network eth0 br99 api ${cluster[@]}

print_banner "Setting up the chef environment"
# at this point, chef server is done, cluster is up.
# let's set up the environment.
create_chef_environment chef-server ${CHEF_ENV}
# Set the package_component environment variable (not really needed in grizzly but no matter)
knife_set_package_component chef-server ${CHEF_ENV} ${PACKAGE_COMPONENT}

# Define vrrp ips
api_vrrp_ip=$(ip_for_host api | awk 'BEGIN{FS="."};{print "10.127.54."$4}')
db_vrrp_ip=$(ip_for_host mysql | awk 'BEGIN{FS="."};{print "10.127.54."$4}')
rabbitmq_vrrp_ip=$(ip_for_host keystone | awk 'BEGIN{FS="."};{print "10.127.54."$4}')
print_banner "VRRP configuration:
API   : ${api_vrrp_ip}
DB    : ${db_vrrp_ip}
RABBIT: ${rabbitmq_vrrp_ip}"

# add the lb service vips to the environment
knife exec -E "@e=Chef::Environment.load('${CHEF_ENV}'); a=@e.override_attributes; \
a['vips']['nova-api']='${api_vrrp_ip}';
a['vips']['nova-ec2-public']='${api_vrrp_ip}';
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

# nodes to prep with base and build-essentials.
prep_list=(keystone glance api api2 horizon compute1 compute2)
for d in "${prep_list[@]}"; do
    background_task role_add chef-server ${d} "role[base],recipe[build-essential]"
done

x_with_cluster "Installing chef-client and running for the first time" ${cluster[@]} <<EOF
flush_iptables
install_chef_client
fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client
EOF


# fix up the storage nodes
x_with_cluster "un-fscking ephemerals" storage1 storage2 storage3 <<EOF
umount /mnt
dd if=/dev/zero of=/dev/vdb bs=1024 count=1024
grep -v "/mnt" /etc/fstab > /tmp/newfstab
cp /tmp/newfstab /etc/fstab
EOF

# fix up api node with a cinder-volumes vg
x_with_cluster "setting up cinder-volumes vg on api node for cinder" api <<EOF
install_package lvm2
umount /mnt
pvcreate /dev/vdb
vgcreate cinder-volumes /dev/vdb
EOF

role_add chef-server api2 "role[mysql-master]"
x_with_cluster "Installing first mysql" api2 <<EOF
chef-client
EOF

role_add chef-server mysql "role[mysql-master]"
x_with_cluster "Installing second mysql" mysql <<EOF
chef-client
EOF

x_with_cluster "Finalising mysql replication on first mysql" api2 <<EOF
chef-client
EOF

# install rabbit message bus early and everywhere it is needed.
role_add chef-server "keystone" "role[rabbitmq-server],role[keystone]"
role_add chef-server "api2" "role[rabbitmq-server]"

x_with_cluster "Installing rabbit/keystone on keystone, rabbit on api2" keystone api2 <<EOF
chef-client
EOF

role_add chef-server proxy "role[swift-management-server],role[swift-setup],role[swift-proxy-server]"

for node_no in {1..3}; do
    role_add chef-server storage${node_no} "role[swift-object-server],role[swift-container-server],role[swift-account-server]"
    set_node_attribute chef-server storage${node_no} "normal/swift" "{\"zone\": ${node_no} }"
done

role_add chef-server glance "role[glance-setup],role[glance-registry],role[glance-api]"

x_with_cluster "Installing glance and swift proxy" proxy glance <<EOF
chef-client
EOF

# setup the role list for api
role_list="role[base],role[nova-setup],role[nova-network-controller],role[nova-conductor],role[nova-scheduler],role[cinder-setup],role[cinder-scheduler],role[cinder-api],role[cinder-volume],role[nova-api-os-compute],role[nova-api-ec2],role[nova-vncproxy],role[glance-registry]"

# skip collectd and graphite on rhel based systems for now.  It is just broke
if [ ${INSTANCE_IMAGE} = "jenkins-precise" ]; then
    role_list+=",role[collectd-client],role[collectd-server],role[graphite]"
fi

role_add chef-server api "$role_list"
role_add chef-server horizon "role[horizon-server],role[openstack-ha]"

x_with_cluster "Installing api/storage nodes/horizon" api storage{1..3} horizon <<EOF
chef-client
EOF

# setup the role list for api2
role_list="role[base],role[cinder-api],role[glance-api],role[nova-conductor],role[nova-scheduler],role[nova-api-os-compute],role[nova-api-ec2],role[swift-proxy-server],role[keystone-api]"
role_add chef-server api2 "$role_list"
x_with_cluster "Running chef on api2" api2 <<EOF
chef-client
EOF

# re-run to discover all back ends for haproxy
x_with_cluster "Running chef on horizon to get haproxy set up properly" horizon <<EOF
chef-client
EOF

role_add chef-server compute1 "role[single-compute]"
role_add chef-server compute2 "role[single-compute]"

# run the proxy to generate the ring, now that we
# have discovered disks (ephemeral0)
x_with_cluster "Running chef on proxy/api/api2/horizon/computes" proxy api api2 horizon compute{1..2} <<EOF
chef-client
EOF

# Now run all the storage servers
x_with_cluster "Running chef on Storage nodes - Pass 2" storage{1..3} <<EOF
chef-client
EOF

role_add chef-server api "recipe[kong],recipe[exerstack]"

# and now pull the rings
x_with_cluster "All nodes - Pass 1" ${cluster[@]} <<EOF
chef-client
EOF

# turn on glance uploads again
set_environment_attribute chef-server ${CHEF_ENV} "override_attributes/glance/image_upload" "true"

# this sucks - but we need to do it because we can't do glance image upload on two nodes at the same time
x_with_cluster "Glance Image Upload" glance <<EOF
chef-client
EOF

# and again, just for good measure.
x_with_cluster "All nodes - Pass 2" ${cluster[@]} <<EOF
chef-client
EOF

x_with_server "Fixerating the API nodes" api <<EOF
fix_for_tests
EOF
background_task "fc_do"
collect_tasks

retval=0

# setup test list
declare -a testlist=(cinder nova glance swift keystone glance-swift)

# run tests
if ( ! run_tests api ${PACKAGE_COMPONENT} ${testlist[@]} ); then
    echo "Tests failed."
    retval=1
fi

x_with_cluster "Fixing log perms" keystone glance api horizon compute1 compute2  <<EOF
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

if [ $retval -eq 0 ]; then
    if [ -n "${GIT_COMMENT_URL}" ] && [ "${GIT_COMMENT_URL}" != "noop" ] ; then
        github_post_comment ${GIT_COMMENT_URL} "Gate:  Nova AIO (${INSTANCE_IMAGE})\n * ${BUILD_URL}consoleFull : SUCCESS"
    else
        echo "skipping building comment"
    fi
fi

END_TIME=$(date +%s)
print_banner "Total time taken was approx $(( (END_TIME-START_TIME)/60 )) minutes"
exit $retval
