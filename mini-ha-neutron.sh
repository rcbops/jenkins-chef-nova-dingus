#!/usr/bin/env bash

START_TIME=$(date +%s)

GRAB_LOGFILES_ON_FAILURE=1
JOB_ARCHIVE_FILES="/var/log,/etc,/var/lib/nova/instances/*/*.xml,/var/lib/nova/instances/*/*.log}"

source $(dirname $0)/chef-jenkins.sh

print_banner "Initializing Job"
init

CHEF_ENV="minicluster-$(derive_chef_environment)"
print_banner "Build Parameters
~~~~~~~~~~~~~~~~
environment = ${CHEF_ENV}
INSTANCE_IMAGE=${INSTANCE_IMAGE}
AVAILABILITY_ZONE=${AZ}
TMPDIR = ${TMPDIR}
GIT_PATCH_URL = ${GIT_PATCH_URL}
GIT_MASTER_URL = ${GIT_MASTER_URL}
We are building branch ${GIT_BRANCH}
We are building on OpenStack $(derive_openstack_version)"

rm -rf logs
mkdir -p logs/run
exec 9>logs/run/out.log
BASH_XTRACEFD=9
set -x

declare -a cluster
cluster=(api api2 compute1 compute2)
#cluster=(api compute1)

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
x_with_cluster "Cluster booted.  Setting up the package providers and quantum networks" ${cluster[@]} <<EOF
ubuntu_fixups
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
stop_timer

start_timer
print_banner "Setting up the chef environment"
# at this point, chef server is done, cluster is up.
# let's set up the environment.
create_chef_environment chef-server ${CHEF_ENV}
stop_timer

# if we have been provided a chef cookbook tarball let's use it otherwise
# upload the cookbooks the normal way.  If we have the tarball the upload
# is initiated from the build server, otherwise all the work is done on the
# chef-server VM
if [[ ! -f ${COOKBOOKS_TARBALL} ]]; then
  start_timer
  x_with_server "uploading the cookbooks" "chef-server" <<EOF
  checkout_cookbooks
  run_twice upload_cookbooks
  run_twice upload_roles
EOF
  background_task "fc_do"
  stop_timer
else
  unpack_local_chef_tarball ${COOKBOOKS_TARBALL}
  upload_local_chef_cookbooks chef-server
  upload_local_chef_roles chef-server
fi

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

start_timer
for i in ${cluster[@]}; do
    role_add chef-server $i 'role[base]'
done

x_with_cluster "Installing chef-client and running with roles" ${cluster[@]} <<EOF
chef-client
install_ovs_package
start_ovs_service
move_ip_to_ovs_bridge eth2
EOF
stop_timer

# fix up api node with a cinder-volumes vg
start_timer
x_with_cluster "setting up cinder-volumes vg on api node for cinder" api <<EOF
install_package lvm2
unmount_filesystem /mnt
pvcreate /dev/vdb
vgcreate cinder-volumes /dev/vdb
EOF
stop_timer

start_timer
role_add chef-server api "role[ha-controller1],role[cinder-volume],role[single-network-node]"
x_with_cluster "Installing the first controller" api <<EOF
chef-client
EOF
stop_timer

start_timer
echo "turning off image upload"
set_environment_attribute chef-server ${CHEF_ENV} "override_attributes/glance/image_upload" "false"
stop_timer

start_timer
role_add chef-server api2 "role[ha-controller2]"
x_with_cluster "Installing the second controller" api2 <<EOF
chef-client
EOF
stop_timer

start_timer
role_add chef-server api "recipe[kong],recipe[exerstack]"
x_with_cluster "Finalizing the installation on the first controller" api <<EOF
chef-client
EOF
stop_timer

start_timer
role_add chef-server compute1 "role[single-compute]"
role_add chef-server compute2 "role[single-compute]"
x_with_cluster "Running chef on the compute nodes" compute1 compute2 <<EOF
chef-client
EOF
stop_timer

start_timer
# this is here so we don't get random image failures with the images
# not syncing from one node to another
x_with_server "stopping glance services on second node" api2 <<EOF
  monit stop glance-api
  monit stop glance-registry
EOF
background_task "fc_do"
collect_tasks
stop_timer

retval=0

# setup test list
declare -a testlist=(cinder nova-neutron nova-quantum neutron quantum glance keystone)

start_timer
# run tests
if ( ! run_tests api $(derive_openstack_version) ${testlist[@]} ); then
    echo "Tests failed."
    retval=1
fi
stop_timer

if [ $retval -eq 0 ]; then
    if [ -n "${GIT_COMMENT_URL}" ] && [ "${GIT_COMMENT_URL}" != "noop" ] ; then
        github_post_comment ${GIT_COMMENT_URL} "Gate:  Nova AIO (${INSTANCE_IMAGE}): SUCCESS\n * ${BUILD_URL}consoleFull"
    else
        echo "skipping building comment"
    fi
fi

END_TIME=$(date +%s)
print_banner "Total time taken was approx $(( (END_TIME-START_TIME)/60 )) minutes"

if [[ -e /usr/bin/figlet ]]; then
  if [[ $retval == 0 ]]; then
    figlet 'SUCCESS!'
  else
    figlet 'FAILURE!'
  fi
fi
exit $retval
