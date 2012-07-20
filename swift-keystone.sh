#!/bin/bash

INSTANCE_IMAGE=6faf41e1-5029-4cdb-8a66-8559b7bd1f1f

source $(dirname $0)/chef-jenkins.sh

init

declare -a cluster
cluster=(keystone proxy storage1 storage2 storage3)

boot_and_wait ${CHEF_IMAGE} chef-server ${CHEF_FLAVOR}
wait_for_ssh $(ip_for_host chef-server)

x_with_server "Uploading cookbooks" "chef-server" <<EOF
COOKBOOK_OVERRIDE=${COOKBOOK_OVERRIDE:-}
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

# at this point, chef server is done, cluster is up.
# let's set up the environment.

create_chef_environment chef-server swift-keystone

# fix up the storage nodes
x_with_cluster "un-fscking ephemerals" storage1 storage2 storage3 <<EOF
umount /mnt
dd if=/dev/zero of=/dev/vdb bs=1024 count=1024
grep -v "/mnt" /etc/fstab > /tmp/newfstab
cp /tmp/newfstab /etc/fstab
EOF

x_with_cluster "Running/registering chef-client" ${cluster[@]} <<EOF
apt-get update
install_chef_client
copy_file validation.pem /etc/chef/validation.pem
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client -ldebug
EOF

# clients are all kicked and inserted into chef server.  Need to
# set up the proper roles for the nodes and go.
set_environment chef-server keystone swift-keystone
set_environment chef-server proxy swift-keystone
set_environment chef-server storage1 swift-keystone
set_environment chef-server storage2 swift-keystone
set_environment chef-server storage3 swift-keystone

role_add chef-server keystone "role[mysql-master]"
role_add chef-server keystone "role[rabbitmq-server]"
role_add chef-server keystone "role[keystone]"
x_with_cluster "Installing keystone" keystone <<EOF
chef-client -ldebug
EOF

role_add chef-server proxy "role[swift-management-server]"
role_add chef-server proxy "role[swift-proxy-server]"

for node_no in {1..3}; do
    role_add chef-server storage${node_no} "role[swift-object-server]"
    role_add chef-server storage${node_no} "role[swift-container-server]"
    role_add chef-server storage${node_no} "role[swift-account-server]"
    set_node_attribute chef-server storage${node_no} "swift" "{\"zone\": ${node_no} }"
done

# run the proxy only first, to set up gits and whatnot
x_with_server "Proxy - Pass 1" proxy <<EOF
chef-client -ldebug
EOF
background_task "fc_do"
collect_tasks

# Now run all the storage servers
x_with_cluster "Storage - Pass 1" storage1 storage2 storage3 <<EOF
chef-client -ldebug
EOF

# run the proxy to generate the ring, now that we
# have discovered disks (ephemeral0)
x_with_cluster "Proxy - Pass 1" proxy <<EOF
chef-client -ldebug
EOF

role_add chef-server proxy "recipe[kong]"
role_add chef-server proxy "recipe[exerstack]"

# and now pull the rings
x_with_cluster "All nodes - Pass 1" ${cluster[@]} <<EOF
chef-client -ldebug
EOF

# and again, just for good measure.
x_with_cluster "All nodes - Pass 2" ${cluster[@]} <<EOF
chef-client -ldebug
EOF
