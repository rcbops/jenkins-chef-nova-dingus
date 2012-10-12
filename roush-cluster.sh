#!/usr/bin/env bash

INSTANCE_IMAGE=${INSTANCE_IMAGE:-jenkins-precise}

source $(dirname $0)/chef-jenkins.sh

init

if [ ${USE_CS} -eq 1 ]; then
    INSTANCE_IMAGE=12.04
fi

declare -a cluster
cluster=(roush-server roush-agent1 roush-agent2)

rm -rf logs
mkdir -p logs/run
exec 9>logs/run/out.log
BASH_XTRACEFD=9
set -x

boot_cluster ${cluster[@]}
wait_for_cluster_ssh ${cluster[@]}

echo "Cluster booted... configuring apt repos"

# need to add build.mpl

# mirrors.rackspace.com is broken right now
cat > ${TMPDIR}/sources.list <<EOF
deb http://mirror.anl.gov/pub/ubuntu/ precise main universe
deb-src http://mirror.anl.gov/pub/ubuntu/ precise main universe
EOF

x_with_cluster "setting apt repo" ${cluster[@]} <<EOF
copy_file ${TMPDIR}/sources.list /etc/apt/sources.list
update_package_provider
flush_iptables
add_repo_key proposed
add_repo proposed
update_package_provider
install_package psmisc
EOF

cat > ${TMPDIR}/roush.conf <<EOF
[main]
base_dir = /usr/share/roush-agent
plugin_dir =/usr/share/roush-agent/plugins
input_handlers = /usr/share/roush-agent/plugins/input/task_input.py
output_handlers = /usr/share/roush-agent/plugins/output
syslog_dev = /dev/log
pidfile = /var/run/roush-agent.pid
include_dir = /etc/roush-agent.d
EOF

cat > ${TMPDIR}/tasks.conf <<EOF
[taskerator]
endpoint=http://$(ip_for_host roush-server):8080
EOF

x_with_server "setting up roush server" roush-server <<EOF
install_package roush-client
install_package roush-simple
install_package roush-agent-input-task
install_package roush-agent-output-adventurator
install_package roush-agent-output-service
install_package roush-agent-output-chef
service roush-agent stop
copy_file ${TMPDIR}/roush.conf /etc/roush-agent.conf
copy_file ${TMPDIR}/tasks.conf /etc/roush-agent.d/tasks.conf
service roush-agent start
EOF
background_task "fc_do"

x_with_cluster "setting up roush client" roush-agent1 roush-agent2 <<EOF
install_package roush-agent
install_package roush-agent-output-chef
install_package roush-agent-input-task
service roush-agent stop
copy_file ${TMPDIR}/roush.conf /etc/roush-agent.conf
copy_file ${TMPDIR}/tasks.conf /etc/roush-agent.d/tasks.conf
service roush-agent start
EOF

x_with_cluster "restarting agent" ${cluster[@]} <<EOF
service roush-agent restart
EOF

echo "ROUSH_ENDPOINT=http://$(ip_for_host roush-server):8080"

echo ${LOGIN}@$(ip_for_host roush-server) > ~/.dsh/group/roush-cluster
echo ${LOGIN}@$(ip_for_host roush-agent1) > ~/.dsh/group/roush-cluster
echo ${LOGIN}@$(ip_for_host roush-agent2) > ~/.dsh/group/roush-cluster


exit $retval
