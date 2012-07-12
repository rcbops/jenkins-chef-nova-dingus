#!/bin/bash

INSTANCE_IMAGE=6faf41e1-5029-4cdb-8a66-8559b7bd1f1f

source ./chef-jenkins.sh

init

declare -a cluster
cluster=(
    "mysql:${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}"
    "keystone:${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}"
    "glance:${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}"
    "api:${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}"
    "horizon:${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}"
    "compute1:${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}"
    "compute2:${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}"
)

boot_and_wait ${CHEF_IMAGE} chef-server ${CHEF_FLAVOR}
wait_for_ssh $(ip_for_host chef-server)

x_with_server "Uploading cookbooks" "chef-server" <<EOF
apt-get update
install_package git-core
rabbitmq_fixup oociahez
checkout_cookbooks
upload_cookbooks
upload_roles
EOF
background_task "fc_do"

boot_cluster ${cluster[@]}
wait_for_cluster_ssh ${cluster[@]}

echo "Cluster booted... configuring chef"


# at this point, chef server is done, cluster is up.
# let's set up the environment.

create_chef_environment chef-server nova

x_with_cluster "Running/registering chef-client" ${cluster[@]} <<EOF
apt-get update
install_chef_client
copy_file validation.pem /etc/chef/validation.pem
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client
EOF

# clients are all kicked and inserted into chef server.  Need to
# set up the proper roles for the nodes and go.
role_add chef-server mysql "role[mysql-master]"
set_environment chef-server mysql nova
x_with_cluster "Installing mysql" ${cluster[@]} <<EOF
chef-client
EOF

role_add chef-server keystone "role[keystone]"
role_add chef-server keystone "role[rabbitmq-server]"
set_environment chef-server keystone nova
x_with_cluster "Installing keystone" ${cluster[@]} <<EOF
chef-client
EOF

role_add chef-server glance "role[glance-api]"
role_add chef-server glance "role[glance-registry]"
set_environment chef-server glance nova
x_with_cluster "Installing glance" ${cluster[@]} <<EOF
chef-client
EOF

role_add chef-server api "role[nova-setup]"
role_add chef-server api "role[nova-scheduler]"
role_add chef-server api "role[nova-api-ec2]"
role_add chef-server api "role[nova-api-os-compute]"
role_add chef-server api "role[nova-vncproxy]"
role_add chef-server api "role[nova-volume]"
role_add chef-server api "recipe[nova::nova-network]"
role_add chef-server api "recipe[kong]"
role_add chef-server api "recipe[exerstack]"
set_environment chef-server api nova
x_with_cluster "Installing API" ${cluster[@]} <<EOF
chef-client
EOF

role_add chef-server horizon "role[horizon-server]"
role_add chef-server compute1 "role[single-compute]"
role_add chef-server compute2 "role[single-compute]"

set_environment chef-server horizon nova
set_environment chef-server compute1 nova
set_environment chef-server compute2 nova

x_with_cluster "Installing the rest of the stack" ${cluster[@]} <<EOF
chef-client
EOF

trap - ERR EXIT

if ( ! run_tests api essex-final ); then
    echo "Tests failed."
    exit 1
fi

exit 0
