#!/usr/bin/env bash

START_TIME=$(date +%s)
INSTANCE_IMAGE=${INSTANCE_IMAGE:-jenkins-precise}

source $(dirname $0)/chef-jenkins.sh

init

declare -a cluster
cluster=(roush node1 node2 node3)

boot_cluster ${cluster[@]}
wait_for_cluster_ssh ${cluster[@]}

# install roush-server
x_with_server "installing roush-server" roush <<EOF
curl -s "http://3199f7b8138ccd4a5141-1f05446a499ccbc56d624169ca685698.r0.cf1.rackcdn.com/install-server.sh" | bash
EOF
background_task "fc_do"

# install roush-agent
x_with_cluster "Installing Roush-Agent" node1 node2 node3 <<EOF
export ROUSH_SERVER=$(ip_for_host roush)
curl -s "http://3199f7b8138ccd4a5141-1f05446a499ccbc56d624169ca685698.r0.cf1.rackcdn.com/install-agent.sh" | bash
EOF

# make sure roush-server looks right
x_with_server "Checking Roush Server" roush <<EOF
r2 node list
EOF
fc_do
