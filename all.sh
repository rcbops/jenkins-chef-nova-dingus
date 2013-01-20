#!/usr/bin/env bash


START_TIME=$(date +%s)
INSTANCE_IMAGE=${INSTANCE_IMAGE:-jenkins-precise}
PACKAGE_COMPONENT=${PACKAGE_COMPONENT:-essex-final}

source $(dirname $0)/chef-jenkins.sh

print_banner "Initializing Job"
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
# Set the package_component environment variable
knife_set_package_component chef-server ${CHEF_ENV} ${PACKAGE_COMPONENT}

# Define vrrp ips
api_vrrp_ip="10.127.54.1${EXECUTOR_NUMBER}"
db_vrrp_ip="10.127.54.10${EXECUTOR_NUMBER}"
rabbitmq_vrrp_ip="10.127.54.20${EXECUTOR_NUMBER}"

# add the lb service vips to the environment
knife exec -E "@e=Chef::Environment.load('${CHEF_ENV}'); a=@e.override_attributes; \
a['vips']['nova-api']='${api_vrrp_ip}';
a['vips']['nova-ec2-public']='${api_vrrp_ip}';
a['vips']['keystone-service-api']='${api_vrrp_ip}';
a['vips']['keystone-admin-api']='${api_vrrp_ip}';
a['vips']['cinder-api']='${api_vrrp_ip}';
a['vips']['swift-proxy']='${api_vrrp_ip}';
a['vips']['rabbitmq-queue']='${rabbitmq_vrrp_ip}';
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
if [ ${PACKAGE_COMPONENT} = "folsom" ]; then
x_with_cluster "setting up cinder-volumes vg on api node for cinder" api <<EOF
install_package lvm2
umount /mnt
pvcreate /dev/vdb
vgcreate cinder-volumes /dev/vdb
EOF
fi

role_add chef-server mysql "role[mysql-master]"
x_with_cluster "Installing mysql" mysql <<EOF
chef-client
EOF

# install rabbit message bus early and everywhere it is needed.
role_add chef-server "keystone" "role[rabbitmq-server]"
role_add chef-server "api2" "role[rabbitmq-server]"

# this needs to be two separate runs because there exists a race condition where
# running this at the same time on two nodes generates different erlang cookies
# and that will break clustering in the next release.  Run it one at a time and
# we won't have any problems.  Darren - fix this!
x_with_cluster "Installing rabbit message bus master on keystone" keystone <<EOF
chef-client
EOF
x_with_cluster "Installing rabbit message bus secondary on api2" api2 <<EOF
chef-client
EOF

role_add chef-server keystone "role[keystone]"
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
role_list="role[base],role[nova-setup],role[nova-network-controller],role[nova-scheduler],role[nova-api-ec2],role[nova-api-os-compute],role[nova-vncproxy]"
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
chef-client
EOF

# setup the role list for api2
# TODO(breu) add swift-proxy-server to the role_list for api2.  It is off now due to a bug.
role_list="role[base],role[glance-api],role[keystone-api],role[nova-scheduler],role[nova-api-os-compute],role[nova-api-ec2]"
if [ $PACKAGE_COMPONENT = "folsom" ] ;then
    role_list="role[base],role[cinder-api],role[glance-api],role[keystone-api],role[nova-scheduler],role[nova-api-os-compute],role[nova-api-ec2]"
fi

role_add chef-server api2 "$role_list"
role_add chef-server compute1 "role[single-compute]"
role_add chef-server compute2 "role[single-compute]"

# run the proxy to generate the ring, now that we
# have discovered disks (ephemeral0)
x_with_cluster "Running chef on proxy/api/horizon/computes" proxy api api2 horizon compute{1..2} <<EOF
chef-client
EOF

# Now run all the storage servers
x_with_cluster "Running chef on Storage nodes - Pass 2" storage{1..3} <<EOF
chef-client
EOF

role_add chef-server api "recipe[kong],recipe[exerstack]"

# Turn on loadbalancing
# TODO(breu): this is broke right now
#role_add chef-server horizon "role[openstack-ha]"

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

# and again on computes, just to ensure mq connectivity
# TODO(breu): is this needed?
x_with_cluster "computes - final pass" compute{1,2} <<EOF
chef-client
EOF

# TODO(breu): verify that we still need this
x_with_server "Fixerating the API nodes - restarting cinder.  Errors on api2 are OK." api api2 <<EOF
fix_for_tests
/usr/sbin/service cinder-volume restart || :
/usr/sbin/service cinder-api restart || :
/usr/sbin/service cinder-scheduler restart || :
EOF
background_task "fc_do"
collect_tasks

retval=0

# allow services chance to reconnect to amqp
print_banner "allowing services to reconnect to amqp...stand by"
sleep 40

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
print_banner "Total time taken was approx $(( (END_TIME-START_TIME)/60 )) minutes"
exit $retval
