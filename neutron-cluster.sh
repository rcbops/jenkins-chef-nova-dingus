#!/usr/bin/env bash


START_TIME=$(date +%s)
PACKAGE_COMPONENT=${PACKAGE_COMPONENT:-grizzly}

GRAB_LOGFILES_ON_FAILURE=1
JOB_ARCHIVE_FILES="/var/log,/etc,/var/lib/nova/instances/*/*.xml,/var/lib/nova/instances/*/*.log}"

source $(dirname $0)/chef-jenkins.sh

print_banner "Initializing Job"
init

CHEF_ENV="minicluster-neutron"
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

setup_quantum_network

print_banner "creating chef server"
boot_and_wait chef-server
wait_for_ssh chef-server

x_with_server "Fixing up the chef-server and booting the cluster" "chef-server" <<EOF
set_package_provider
update_package_provider
flush_iptables
run_twice install_package git-core
fixup_hosts_file_for_quantum
chef11_fixup
EOF
background_task "fc_do"

boot_cluster ${cluster[@]}

print_banner "Waiting for IP connectivity to the instances"
wait_for_cluster_ssh ${cluster[@]}
print_banner "Waiting for SSH to become available"
wait_for_cluster_ssh_key ${cluster[@]}

x_with_cluster "Cluster booted.  Setting up the package providers and quantum networks" ${cluster[@]} <<EOF
plumb_quantum_networks eth1
plumb_quantum_networks eth2
# set_quantum_network_link_up eth2
cleanup_metadata_routes eth0 eth1
fixup_hosts_file_for_quantum
wait_for_rhn
set_package_provider
update_package_provider
run_twice install_package bridge-utils
EOF

print_banner "Setting up the chef environment"
# at this point, chef server is done, cluster is up.
# let's set up the environment.
create_chef_environment chef-server ${CHEF_ENV}
# Set the package_component environment variable (not really needed in grizzly but no matter)
knife_set_package_component chef-server ${CHEF_ENV} ${PACKAGE_COMPONENT}

x_with_cluster "Installing chef-client and running for the first time" ${cluster[@]} <<EOF
flush_iptables
install_chef_client
chef11_fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client
EOF

for i in ${cluster[@]}; do
  role_add chef-server $i 'role[base]'
done

x_with_cluster "Installing OVS packages" ${cluster[@]} <<EOF
chef-client
install_ovs_package
/etc/init.d/openvswitch start || true
move_ip_to_ovs_bridge eth2
EOF

# fix up api node with a cinder-volumes vg
x_with_cluster "setting up cinder-volumes vg on api node for cinder" api <<EOF
install_package lvm2
unmount_filesystem /mnt
pvcreate /dev/vdb
vgcreate cinder-volumes /dev/vdb
EOF

role_add chef-server api "role[ha-controller1],role[cinder-volume],role[single-network-node]"
role_add chef-server api2 "role[ha-controller2]"
role_add chef-server api "recipe[kong],recipe[exerstack]"
role_add chef-server compute1 "role[single-compute]"
role_add chef-server compute2 "role[single-compute]"

exit 1
