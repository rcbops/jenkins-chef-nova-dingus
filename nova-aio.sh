#!/bin/bash

INSTANCE_IMAGE=6faf41e1-5029-4cdb-8a66-8559b7bd1f1f

source $(dirname $0)/chef-jenkins.sh

init

declare -a cluster
cluster=(
    "nova-aio:${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}"
)

boot_and_wait ${CHEF_IMAGE} chef-server ${CHEF_FLAVOR}
wait_for_ssh $(ip_for_host chef-server)

x_with_server "Uploading chef cookbooks" "chef-server" <<EOF
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

x_with_cluster "Installing/registering chef client" ${cluster[@]} <<EOF
apt-get update
install_chef_client
copy_file validation.pem /etc/chef/validation.pem
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client
EOF

# clients are all kicked and inserted into chef server.  Need to
# set up the proper roles for the nodes and go.
role_add chef-server nova-aio "role[single-controller]"
role_add chef-server nova-aio "role[single-compute]"
role_add chef-server nova-aio  "recipe[kong]"
role_add chef-server nova-aio "recipe[exerstack]"
set_environment chef-server nova-aio nova

x_with_cluster "Running first chef pass" ${cluster[@]} <<EOF
chef-client
EOF

if ( ! run_tests nova-aio essex-final ); then
    echo "Tests failed."
    exit 1
fi

touch foo.log

exit 0
