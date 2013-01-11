#!/usr/bin/env bash

START_TIME=$(date +%s)
INSTANCE_IMAGE=${INSTANCE_IMAGE:-jenkins-precise}
PACKAGE_COMPONENT=${PACKAGE_COMPONENT:-essex-final}

source $(dirname $0)/chef-jenkins.sh

init

CHEF_ENV="bigcluster"
echo "using environment ${CHEF_ENV}"
echo "Using INSTANCE_IMAGE ${INSTANCE_IMAGE}"
echo "Building for ${PACKAGE_COMPONENT}"

rm -rf logs
mkdir -p logs/run
exec 9>logs/run/out.log
BASH_XTRACEFD=9
set -x

declare -a cluster
cluster=(mysql keystone glance api api2 horizon compute1 compute2 proxy storage1 storage2 storage3 graphite)

boot_and_wait chef-server
wait_for_ssh $(ip_for_host chef-server)

x_with_server "Uploading cookbooks" "chef-server" <<EOF
set_package_provider
update_package_provider
flush_iptables
run_twice install_package git-core
rabbitmq_fixup
chef_fixup
run_twice checkout_cookbooks
run_twice upload_cookbooks
run_twice upload_roles
EOF
background_task "fc_do"

boot_cluster ${cluster[@]}
wait_for_cluster_ssh ${cluster[@]}

echo "Cluster booted... setting up vpn thing"
x_with_cluster "installing bridge-utils" ${cluster[@]} <<EOF
wait_for_rhn
set_package_provider
update_package_provider
run_twice install_package bridge-utils
EOF
setup_private_network eth0 br99 api ${cluster[@]}

# at this point, chef server is done, cluster is up.
# let's set up the environment.

create_chef_environment chef-server ${CHEF_ENV}
# Set the package_component environment variable
knife_set_package_component chef-server ${CHEF_ENV} ${PACKAGE_COMPONENT}

# Define vrrp ips
api_vrrp_ip="10.127.55.1${EXECUTOR_NUMBER}"
db_vrrp_ip="10.127.55.10${EXECUTOR_NUMBER}"

# add the lb service vips to the environment
knife exec -E "@e=Chef::Environment.load('${CHEF_ENV}'); a=@e.override_attributes; \
a['vips']['nova-api']='${api_vrrp_ip}';
a['vips']['nova-ec2-public']='${api_vrrp_ip}';
a['vips']['keystone-service-api']='${api_vrrp_ip}';
a['vips']['keystone-admin-api']='${api_vrrp_ip}';
a['vips']['cinder-api']='${api_vrrp_ip}';
a['vips']['swift-proxy']='${api_vrrp_ip}';
@e.override_attributes(a); @e.save" -c ${TMPDIR}/chef/chef-server/knife.rb

# Disable glance image_uploading
set_environment_attribute chef-server ${CHEF_ENV} "override_attributes/glance/image_upload" "false"

# fix up the storage nodes
x_with_cluster "un-fscking ephemerals" storage1 storage2 storage3 <<EOF
umount /mnt
dd if=/dev/zero of=/dev/vdb bs=1024 count=1024
grep -v "/mnt" /etc/fstab > /tmp/newfstab
cp /tmp/newfstab /etc/fstab
EOF

# fix up api node with a cinder-volumes vg
if [ ${PACKAGE_COMPONENT} = "folsom" ]; then
x_with_cluster "setting up cinder-volumes vg on api node for cinder" api <<EOF
install_package lvm2
umount /mnt
pvcreate /dev/vdb
vgcreate cinder-volumes /dev/vdb
EOF
fi

x_with_cluster "Running/registering chef-client" ${cluster[@]} <<EOF
flush_iptables
install_chef_client
fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client
EOF

# set the environment in one shot
#set_environment_all chef-server ${CHEF_ENV}

# nodes to prep with base and build-essentials.
prep_list=(keystone glance api api2 horizon compute1 compute2)
for d in "${prep_list[@]}"; do
    x_with_server "prep chef with base role on instance ${d}" ${d} <<EOF
prep_chef_client
EOF
    background_task "fc_do"
done

role_add chef-server mysql "role[mysql-master]"
x_with_cluster "Installing mysql" mysql <<EOF
chef-client
EOF

role_add chef-server keystone "role[rabbitmq-server],role[keystone]"
x_with_cluster "Installing keystone" keystone <<EOF
chef-client
EOF

role_add chef-server proxy "role[swift-management-server],role[swift-proxy-server]"

for node_no in {1..3}; do
    role_add chef-server storage${node_no} "role[swift-object-server],role[swift-container-server],role[swift-account-server]"
    set_node_attribute chef-server storage${node_no} "normal/swift" "{\"zone\": ${node_no} }"
done

role_add chef-server glance "role[glance-registry],role[glance-api]"

x_with_cluster "Installing glance and swift proxy" proxy glance <<EOF
chef-client
EOF

# setup the role list for api
role_list="role[base],role[nova-setup],role[nova-network-setup],role[nova-scheduler],role[nova-api-ec2],role[nova-api-os-compute],role[nova-vncproxy]"
case "$PACKAGE_COMPONENT" in
essex-final) role_list+=",role[nova-volume]"
             ;;
folsom)      role_list+=",role[cinder-setup],role[cinder-scheduler],role[cinder-api],role[cinder-volume]"
             ;;
*)           echo "WARNING!  UNKNOWN PACKAGE_COMPONENT ($PACKAGE_COMPONENT)"
             exit 100
             ;;
esac

# skip collectd and graphite on rhel based systems for now.  It is just broke
if [ ${INSTANCE_IMAGE} = "jenkins-precise" ]; then
    role_list+=",role[collectd-client],role[collectd-server],role[graphite]"
fi

role_add chef-server api "$role_list"
role_add chef-server horizon "role[horizon-server]"

x_with_cluster "Installing api/storage nodes/horizon" api storage{1..3} horizon <<EOF
chef-client -ldebug
EOF

# setup the role list for api2
role_list="role[base],role[glance-api],role[keystone-api],role[nova-api-os-compute],role[nova-api-ec2],role[swift-proxy-server]"
if [ $PACKAGE_COMPONENT = "folsom" ] ;then
    role_list="role[base],role[cinder-api],role[glance-api],role[keystone-api],role[nova-api-os-compute],role[nova-api-ec2],role[swift-proxy-server]"
fi

role_add chef-server api2 "$role_list"
role_add chef-server compute1 "role[single-compute]"
role_add chef-server compute2 "role[single-compute]"

# run the proxy to generate the ring, now that we
# have discovered disks (ephemeral0)
x_with_cluster "proxy/api/horizon/computes" proxy api api2 horizon compute{1..2} <<EOF
chef-client
EOF

# Now run all the storage servers
x_with_cluster "Storage - Pass 2" storage{1..3} <<EOF
chef-client
EOF

role_add chef-server api "recipe[kong],recipe[exerstack]"

# Turn on loadbalancing
role_add chef-server horizon "role[openstack-ha]"

# and now pull the rings
x_with_cluster "All nodes - Pass 1" ${cluster[@]} <<EOF
chef-client
EOF

# turn on glance uploads again
set_environment_attribute chef-server ${CHEF_ENV} "override_attributes/glance/image_upload" "true"

# this sucks - but we need to do it because we can't do glance image upload on two nodes at the time
# time.
x_with_cluster "Glance Image Upload" glance <<EOF
chef-client
EOF

# and again, just for good measure.
x_with_cluster "All nodes - Pass 2" ${cluster[@]} <<EOF
chef-client
EOF

x_with_server "fixerating" api <<EOF
fix_for_tests
EOF
background_task "fc_do"
collect_tasks

retval=0

# setup test list
declare -a testlist=(nova glance swift keystone glance-swift)
if [ ${PACKAGE_COMPONENT} = "folsom" ]; then
    testlist=("cinder" "${testlist[@]}")
fi

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
echo "Total time taken was approx $(( (END_TIME-START_TIME)/60 )) minutes"
exit $retval
