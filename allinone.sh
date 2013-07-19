#!/usr/bin/env bash


START_TIME=$(date +%s)
PACKAGE_COMPONENT=${PACKAGE_COMPONENT:-grizzly}

GRAB_LOGFILES_ON_FAILURE=1
JOB_ARCHIVE_FILES="/var/log,/etc,/var/lib/nova/instances/*/*.xml,/var/lib/nova/instances/*/*.log}"

source $(dirname $0)/chef-jenkins.sh

print_banner "Initializing Job"
init

CHEF_ENV="allinone"
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
cluster=(api)

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

x_with_cluster "Cluster booted.  Setting up the package providers and dummy interface..." ${cluster[@]} <<EOF
plumb_quantum_networks eth1
# set_quantum_network_link_up eth2
cleanup_metadata_routes eth0 eth1 
fixup_hosts_file_for_quantum
wait_for_rhn
set_package_provider
update_package_provider
run_twice install_package bridge-utils
modprobe dummy
ip l s dummy0 up
EOF
stop_timer

start_timer
print_banner "Setting up the chef environment"
# at this point, chef server is done, cluster is up.
# let's set up the environment.
create_chef_environment chef-server ${CHEF_ENV}
# Set the package_component environment variable (not really needed in grizzly but no matter)
knife_set_package_component chef-server ${CHEF_ENV} ${PACKAGE_COMPONENT}
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


# fix up api node with a cinder-volumes vg
start_timer
x_with_cluster "setting up cinder-volumes vg on api node for cinder" api <<EOF
install_package lvm2
umount /mnt
pvcreate /dev/vdb
vgcreate cinder-volumes /dev/vdb
EOF
stop_timer

set_environment_attribute chef-server ${CHEF_ENV} "override_attributes/glance/image_upload" "true"

start_timer
role_add chef-server api "role[allinone],role[cinder-volume],recipe[kong],recipe[exerstack]"
x_with_cluster "Installing everyting" api <<EOF
chef-client
EOF
stop_timer

start_timer
x_with_cluster "Running chef again so we can lay down the EC2 credentials correctly" api <<EOF
chef-client
EOF
stop_timer

retval=0

# setup test list
declare -a testlist=(cinder nova glance keystone)

start_timer
# run tests
if ( ! run_tests api ${PACKAGE_COMPONENT} ${testlist[@]} ); then
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
exit $retval
