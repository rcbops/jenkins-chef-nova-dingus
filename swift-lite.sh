#!/usr/bin/env bash


START_TIME=$(date +%s)
PACKAGE_COMPONENT=${PACKAGE_COMPONENT:-grizzly}
CHEF_IMAGE=chef-template5

source $(dirname $0)/chef-jenkins.sh

print_banner "Initializing Job"
init

CHEF_ENV="swift-lite"
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
cluster=(keystone proxy1 storage1 storage2 storage3)

start_timer
setup_quantum_network
stop_timer

start_timer
print_banner "creating chef server"
boot_and_wait chef-server
wait_for_ssh chef-server
stop_timer

start_timer
x_with_server "Fixing up the chef-server and booting the cluster" "chef-server" <<EOF
set_package_provider
update_package_provider
flush_iptables
run_twice install_package git-core
fixup_hosts_file_for_quantum
chef11_fixup
run_twice checkout_cookbooks
git clone http://github.com/rpedde-rcbops/swift-lite chef-cookbooks/cookbooks/swift-lite
knife role from file chef-cookbooks/cookbooks/swift-lite/contrib/roles/*.rb
EOF
background_task "fc_do"

boot_cluster ${cluster[@]}
stop_timer

start_timer
print_banner "Waiting for IP connectivity to the instances"
wait_for_cluster_ssh ${cluster[@]}
print_banner "Waiting for SSH to become available"
wait_for_cluster_ssh_key ${cluster[@]}
stop_timer

start_timer
x_with_server "uploading the cookbooks" "chef-server" <<EOF
run_twice upload_cookbooks
run_twice upload_roles
EOF
background_task "fc_do"

x_with_cluster "Cluster booted.  Setting up the package providers and vpn thingy..." ${cluster[@]} <<EOF
plumb_quantum_networks eth1
# set_quantum_network_link_up eth2
cleanup_metadata_routes eth0 eth1
fixup_hosts_file_for_quantum
wait_for_rhn
set_package_provider
update_package_provider
run_twice install_package bridge-utils
EOF
stop_timer

start_timer
print_banner "Setting up the chef environment"
# at this point, chef server is done, cluster is up.
# let's set up the environment.
create_chef_environment chef-server swift-lite
create_chef_environment chef-server swift-keystone

# Set the package_component environment variable (not really needed in grizzly but no matter)
knife_set_package_component chef-server ${CHEF_ENV} ${PACKAGE_COMPONENT}
stop_timer

# add_chef_clients chef-server ${cluster[@]} # what does this do?

start_timer
x_with_cluster "Installing chef-client and running for the first time" ${cluster[@]} <<EOF
flush_iptables
install_chef_client
chef11_fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client
EOF
stop_timer

set_environment chef-server keystone swift-keystone
set_environment_all chef-server swift-lite

role_add chef-server keystone "recipe[osops-utils::packages]"
role_add chef-server keystone "role[mysql-master]"
role_add chef-server keystone "role[keystone]"

x_with_cluster "installing keystone" keystone <<EOF
chef-client
EOF
