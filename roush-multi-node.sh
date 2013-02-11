#!/usr/bin/env bash

START_TIME=$(date +%s)
INSTANCE_IMAGE=${INSTANCE_IMAGE:-jenkins-precise}

source $(dirname $0)/chef-jenkins.sh

init

declare -a cluster
cluster=(roush:jenkins-precise:roush node1:jenkins-precise:roush node2:jenkins-precise:roush node3:jenkins-precise:roush)

boot_cluster ${cluster[@]}
wait_for_cluster_ssh ${cluster[@]}

# install roush-server
x_with_server "installing roush-server" roush <<EOF
curl -s "https://bcd46edb6e5fd45555c0-409026321750f2e680f86e05ff37dd6d.ssl.cf1.rackcdn.com/install-server.sh" | bash
EOF
background_task "fc_do"

# install roush-agent
x_with_cluster "Installing Roush-Agent" node1 node2 node3 <<EOF
export ROUSH_SERVER=$(ip_for_host roush)
curl -s "https://bcd46edb6e5fd45555c0-409026321750f2e680f86e05ff37dd6d.ssl.cf1.rackcdn.com//install-agent.sh" | bash
EOF

# make sure roush-server looks right
x_with_server "Running Happy Path Tests" roush <<EOF
make_roush_log_dev_null
service roush restart
apt-get install -y git
cd /opt
git clone https://github.com/galstrom21/roush-testerator.git
cd roush-testerator
echo "export ROUSH_ENDPOINT=http://$(ip_for_host roush):8080" > localrc
echo "export INSTANCE_SERVER_HOSTNAME=$(hostname_for_host node1).novalocal" >> localrc
echo "export INSTANCE_CONTROLLER_HOSTNAME=$(hostname_for_host node2).novalocal" >> localrc
echo "export INSTANCE_COMPUTE_HOSTNAME=$(hostname_for_host node3).novalocal" >> localrc
source localrc; ./run_tests.sh -V
EOF
fc_do
