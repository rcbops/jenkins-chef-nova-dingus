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
sleep 30s
wait_for_cluster_ssh ${cluster[@]}

echo "Cluster booted... configuring apt repos"

# need to add build.mpl

cat > ${TMPDIR}/sources.list <<EOF
deb http://mirror.rackspace.com/ubuntu/ precise main universe
deb http://mirror.rackspace.com/ubuntu/ precise-updates main universe
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
bind_address = 0.0.0.0
bind_port = 8080
backend = /usr/share/roush/backends
database_uri = sqlite:////usr/share/roush/roush.db
pidfile = /var/run/roush.pid

[ChefClientBackend]
knife_file = /root/.chef/knife.rb
role_location = /usr/share/roush/roles
EOF

cat > ${TMPDIR}/roush-agent.conf <<EOF
[main]
base_dir = /usr/share/roush-agent
plugin_dir =/usr/share/roush-agent/plugins
input_handlers = /usr/share/roush-agent/plugins/input/task_input.py
output_handlers = /usr/share/roush-agent/plugins/output
log_config = /usr/share/roush-agent/log.cfg
log_file = /var/log/roush-agent.log
log_level = DEBUG
#syslog_dev = /dev/log
pidfile = /var/run/roush-agent.pid
include_dir = /etc/roush-agent.d
EOF

cat > ${TMPDIR}/log.cfg <<EOF
[loggers]
keys=root

[handlers]
keys=file

[formatters]
keys=default

[logger_root]
level=INFO
handlers=syslog

[handler_stderr]
class=StreamHandler
level=NOTSET
#formatter=default
args=(sys.stderr,)

[handler_syslog]
class=logging.handlers.SysLogHandler
level=NOTSET
#formatter=default
args=("/dev/log",)

[handler_file]
class=FileHandler
level=NOTSET
#formatter=default
args=('/var/logroush-agent.log')

[formatter_default]
format=%(asctime)s - %(name)s - %(levelname)s - %(message)s
class=logging.Formatter
datefmt=%Y-%m-%d %H:%M:%S
EOF

cat > ${TMPDIR}/tasks.conf <<EOF
[taskerator]
endpoint=http://$(ip_for_host roush-server):8080
EOF

x_with_server "setting up roush server" roush-server <<EOF
install_package roush-client roush roush-simple roush-agent roush-agent-input-task
install_package roush-agent-output-chef roush-agent-output-service roush-agent-output-adventurator
service roush-agent stop || /bin/true
service roush stop || /bin/true
copy_file ${TMPDIR}/roush.conf /usr/share/roush/roush.conf
copy_file ${TMPDIR}/roush-agent.conf /etc/roush-agent.conf
copy_file ${TMPDIR}/tasks.conf /etc/roush-agent.d/tasks.conf
copy_file ${TMPDIR}/log.cfg /usr/share/roush/log.cfg
service roush start || /bin/true
service roush-agent start || /bin/true
EOF
background_task "fc_do"

x_with_cluster "setting up roush client" roush-agent1 roush-agent2 <<EOF
install_package roush-agent roush-agent-output-chef roush-agent-input-task
service roush-agent stop || /bin/true
copy_file ${TMPDIR}/roush-agent.conf /etc/roush-agent.conf
copy_file ${TMPDIR}/tasks.conf /etc/roush-agent.d/tasks.conf
copy_file ${TMPDIR}/log.cfg /usr/share/roush/log.cfg
service roush-agent start || /bin/true
EOF

x_with_cluster "restarting agent" ${cluster[@]} <<EOF
service roush-agent restart
EOF

echo "ROUSH_ENDPOINT=http://$(ip_for_host roush-server):8080"

echo ${LOGIN}@$(ip_for_host roush-server) > ~/.dsh/group/roush-cluster
echo ${LOGIN}@$(ip_for_host roush-agent1) >> ~/.dsh/group/roush-cluster
echo ${LOGIN}@$(ip_for_host roush-agent2) >> ~/.dsh/group/roush-cluster


exit $retval
