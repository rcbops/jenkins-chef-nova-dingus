#!/bin/bash

#INSTANCE_IMAGE=6faf41e1-5029-4cdb-8a66-8559b7bd1f1f
CHEF_IMAGE=chef
INSTANCE_IMAGE=bridge-precise
# CHEF_FLAVOR=3
# IMAGE_FLAVOR=3

source $(dirname $0)/chef-jenkins.sh

init

if [ ${USE_CS} -eq 1 ]; then
    INSTANCE_IMAGE=ubuntu-precise
fi

declare -a cluster
cluster=(nova-aio)

rm -rf logs
mkdir -p logs/run
exec 9>logs/run/out.log
BASH_XTRACEFD=9
set -x

boot_and_wait chef-server
wait_for_ssh $(ip_for_host chef-server)

x_with_server "Uploading chef cookbooks" chef-server <<EOF
apt-get update
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

echo "Cluster booted... configuring chef"

# at this point, chef server is done, cluster is up.
# let's set up the environment.

create_chef_environment chef-server nova-aio

x_with_cluster "Installing/registering chef client" nova-aio <<EOF
apt-get update
flush_iptables
install_chef_client
fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client -ldebug
EOF

# clients are all kicked and inserted into chef server.  Need to
# set up the proper roles for the nodes and go.
role_add chef-server nova-aio "role[single-controller]"
role_add chef-server nova-aio "role[single-compute]"
role_add chef-server nova-aio "recipe[kong]"
role_add chef-server nova-aio "recipe[exerstack]"
set_environment chef-server nova-aio nova-aio

x_with_cluster "Running first chef pass" nova-aio <<EOF
chef-client -ldebug
EOF

retval=0
if ( ! run_tests nova-aio essex-final nova glance keystone); then
    echo "Tests failed."
    retval=1
fi

# let's grab the logs
x_with_cluster "Fixing log perms" nova-aio <<EOF
chmod 755 /var/log/nova
EOF

cluster_fetch_file "/var/log/{nova,glance,keystone}/*log" ./logs ${cluster[@]}

if [ $retval -eq 0 ]; then
    github_post_comment ${GIT_COMMENT_URL} "Gate:  Nova AIO\n * ${BUILD_URL}consoleFull : SUCCESS"
fi

exit $retval
