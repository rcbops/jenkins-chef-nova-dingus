#!/usr/bin/env bash

INSTANCE_IMAGE=${INSTANCE_IMAGE:-bridge-precise}

source $(dirname $0)/chef-jenkins.sh

init

if [ ${USE_CS} -eq 1 ]; then
    INSTANCE_IMAGE=ubuntu-precise
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

x_with_cluster "setting apt repo" ${cluster[@]} <<EOF
update_package_provider
flush_iptables
add_repo_key proposed
add_repo proposed
update_package_provider
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
service roush-agent stop
copy_file ${TMPDIR}/roush.conf /etc/roush-agent.conf
copy_file ${TMPDIR}/tasks.conf /etc/roush-agent.d/tasks.conf
killall -9 python
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
killall -9 python
service roush-agent start
EOF

x_with_cluster "restarting agent" ${cluster[@]} <<EOF
service roush-agent restart
EOF

exit $retval
