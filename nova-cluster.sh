#!/usr/bin/env bash

#INSTANCE_IMAGE=6faf41e1-5029-4cdb-8a66-8559b7bd1f1f
CHEF_IMAGE=chef
INSTANCE_IMAGE=${INSTANCE_IMAGE:-bridge-precise}

source $(dirname $0)/chef-jenkins.sh

init

if [ ${USE_CS} -eq 1 ]; then
    INSTANCE_IMAGE=ubuntu-precise
fi

declare -a cluster
cluster=(mysql keystone glance api horizon compute1 compute2)

boot_and_wait chef-server
wait_for_ssh $(ip_for_host chef-server)

x_with_server "Uploading cookbooks" chef-server <<EOF
update_package_provider
flush_iptables
install_package git-core
rabbitmq_fixup
chef_fixup
checkout_cookbooks
upload_cookbooks
upload_roles
EOF
background_task "fc_do"

boot_cluster ${cluster[@]}
wait_for_cluster_ssh ${cluster[@]}

echo "Cluster booted... setting up vpn thing"
setup_private_network br100 br99 api ${cluster[@]}

# at this point, chef server is done, cluster is up.
# let's set up the environment.

create_chef_environment chef-server nova-cluster

x_with_cluster "Running/registering chef-client" ${cluster[@]} <<EOF
update_package_provider
flush_iptables
install_chef_client
fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client -ldebug
EOF

# clients are all kicked and inserted into chef server.  Need to
# set up the proper roles for the nodes and go.
set_environment chef-server mysql nova-cluster
set_environment chef-server keystone nova-cluster
set_environment chef-server glance nova-cluster
set_environment chef-server api nova-cluster
set_environment chef-server horizon nova-cluster
set_environment chef-server compute1 nova-cluster
set_environment chef-server compute2 nova-cluster

x_with_cluster "Empty Run" ${cluster[@]} <<EOF
chef-client -ldebug
EOF

role_add chef-server mysql "role[mysql-master]"
x_with_cluster "Installing mysql" ${cluster[@]} <<EOF
chef-client -ldebug
EOF

role_add chef-server keystone "role[rabbitmq-server]"
role_add chef-server keystone "role[keystone]"
x_with_cluster "Installing keystone" ${cluster[@]} <<EOF
chef-client -ldebug
EOF

role_add chef-server glance "role[glance-registry]"
role_add chef-server glance "role[glance-api]"

x_with_cluster "Installing glance" ${cluster[@]} <<EOF
chef-client -ldebug
EOF

role_add chef-server api "role[nova-setup]"
role_add chef-server api "role[nova-scheduler]"
role_add chef-server api "role[nova-api-ec2]"
role_add chef-server api "role[nova-api-os-compute]"
role_add chef-server api "role[nova-vncproxy]"
role_add chef-server api "role[nova-volume]"

x_with_cluster "Installing nova infra/API" ${cluster[@]} <<EOF
chef-client -ldebug
EOF

role_add chef-server api "recipe[kong]"
role_add chef-server api "recipe[exerstack]"
role_add chef-server horizon "role[horizon-server]"
role_add chef-server compute1 "role[single-compute]"
role_add chef-server compute2 "role[single-compute]"

x_with_cluster "Installing the rest of the stack" ${cluster[@]} <<EOF
chef-client -ldebug
EOF

x_with_server "Ip-ing API bridge" api <<EOF
ip addr add 192.168.100.254/24 dev br99
EOF
fc_do

if ( ! run_tests api essex-final nova glance keystone ); then
    echo "Tests failed."
    exit 1
fi

exit 0
