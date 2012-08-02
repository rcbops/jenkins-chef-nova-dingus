#!/bin/bash

set -u
set -e
set -x

PLATFORM=debian
COOKBOOK_PATH=/root
GIT_MASTER_URL=${GIT_MASTER_URL:-https://github.com/rcbops/chef-cookbooks}
COOKBOOK_OVERRIDE=""

if [ -e /etc/redhat-release ]; then
    PLATFORM=redhat
else
    PLATFORM=debian
fi

function install_package() {
    if [ $PLATFORM = "debian" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --force-yes "$@"
    else
        yum install "$@"
    fi
}

function rabbitmq_fixup() {
    local amqp_password=$(egrep "^amqp_pass" /etc/chef/server.rb | awk '{ print $2 }' | tr -d '"')

    # sometimes rabbit gets mad about hostnames changing
    # when booting from a snapshotted instance...
    if ! /etc/init.d/rabbitmq-server restart; then
        local pid=$(ps auxw | grep "/var/lib/rabbi[t]" | awk '{ print $2 }')
        if [ "${pid:-}" != "" ]; then
            kill $pid
            /etc/init.d/rabbitmq-server start
            sleep 5
        fi
    fi

    if (! rabbitmqctl list_vhosts | grep -q chef ); then
        rabbitmqctl add_vhost /chef
        rabbitmqctl add_user chef ${amqp_password}
        rabbitmqctl set_permissions -p /chef chef ".*" ".*" ".*"
    fi
}


function chef_fixup() {
    cat > ${HOME}/.chef/knife.rb <<EOF
log_level                :info
log_location             STDOUT
node_name                'chefadmin'
client_key               '${HOME}/.chef/chefadmin.pem'
validation_client_name   'chef-validator'
validation_key           '${HOME}/.chef/validation.pem'
chef_server_url          'http://localhost:4000'
cache_type               'BasicFile'
cache_options( :path => '${HOME}/.chef/checksums' )
EOF

    # This is totally dangerously stupid
    mkdir -p /etc/chef
    cp /etc/chef/validation.pem /usr/share/chef-server-api/public
    cp ${HOME}/.chef/chefadmin.pem /usr/share/chef-server-api/public
    chmod 644 /usr/share/chef-server-api/public/chefadmin.pem
    chmod 644 /usr/share/chef-server-api/public/validation.pem
}

function checkout_cookbooks() {
    declare -a overrides
    local override

    mkdir -p ${COOKBOOK_PATH}
    cd ${COOKBOOK_PATH}

    local master_url=${GIT_MASTER_URL//,/ }
    declare -a master_info=(${master_url})
    local master_repo=${master_info[0]}
    local master_branch=${master_info[1]:-sprint}

    git clone ${master_repo}

    mkdir -p chef-cookbooks
    cd chef-cookbooks
    git checkout ${master_branch}
    git submodule init
    git submodule update

    pushd cookbooks
    # Okay, now start going through the overrides
    overrides=(${COOKBOOK_OVERRIDE-})
    if [ ! -z "${overrides:-}" ]; then
        for override in ${overrides[@]}; do
            echo "Doing override: ${override}"
            declare -a repo_info
            repo_info=(${override//,/ })
            local repo=${repo_info[0]}
            local branch=${repo_info[1]:-master}
            local dirname=${repo##*/}

            if [ -e ${dirname} ]; then
                rm -rf ${dirname}
            fi

            git clone ${repo}
            pushd ${dirname}
            git checkout ${branch}
            popd
        done
    fi

    # If the overrides are specified as a git patch,
    # apply that patch, too
    if [ "${GIT_PATCH_URL:-}" != "" ]; then
        if [ "${GIT_REPO:-}" != "" ]; then
            cd ${GIT_REPO}
            curl -s ${GIT_PATCH_URL} | git am
        fi
    fi

    popd

}

function upload_cookbooks() {
    cd ${COOKBOOK_PATH}/chef-cookbooks

    knife cookbook upload -o cookbooks -a
}

function upload_roles() {
    cd ${COOKBOOK_PATH}/chef-cookbooks

    rake roles
}

function install_chef_client() {
    local extra_packages

    case $PLATFORM in
        debian|ubuntu)
            extra_packages="wget curl build-essential automake cgroup-lite"
            ;;
        redhat|fedora|centos|scientific)
            extra_packages="wget tar"
            ;;
    esac

    install_package ${extra_packages}

    if [ $PLATFORM = "debian" ] || [ $PLATFORM = "ubuntu" ]; then
        /usr/bin/cgroups-mount  # ?
    fi

    curl -skS http://s3.amazonaws.com/opscode-full-stack/install.sh | /bin/bash &
    wait $!
}

function swap_apt_source() {
    # $1 - new mirror (not mirror.rackspace.com)
    #
    sed -i /etc/apt/sources.list -e "s/mirror.rackspace.com/${1}/g"
}

function fetch_validation_pem() {
    # $1 - IP of chef server
    local ip=$1
    mkdir -p /etc/chef
    rm -f /etc/chef/validation.pem
    wget -nv http://${ip}:4000/validation.pem -O /etc/chef/validation.pem
}

function copy_file() {
    # $1 - file name
    # $2 - local path
    local file=$1
    local path=$2

    mkdir -p $(dirname ${path})
    cp /tmp/fakeconfig/${file} ${path}
}

function gretap_to_host() {
    # $1 - bridge
    # $2 - local device
    # $3 - remote ip
    # $4 - name

    local bridge=$1
    local device=$2
    local remote=$3
    local name=$4

    modprobe ip_gre

    local addr=$(ip addr show ${device} | grep "inet " | awk '{ print $2 }' | cut -d/ -f1)

    if ( ! ip link show dev ${bridge} ); then
        brctl addbr ${bridge}
        ip link set ${bridge} up
    fi

    if [ "${addr}" = "${remote}" ]; then
        # can't link to myself.  duh.
        return 0
    fi

    ip link add gretap.${name} type gretap local ${addr} remote ${remote}
    ip link set dev gretap.${name} up
    brctl addif ${bridge} gretap.${name}
}


# throw eth0 into br100 and swap ips.
function bridge_whoop_de_do() {
    if [ $PLATFORM = "debian" ] || [ $PLATFORM = "ubuntu" ]; then
        install_package "bridge-utils"
    fi

    # get the eth0 addr
    local addr=$(ip addr show eth0 | grep "inet " | awk '{ print $2 }')

    ip addr del ${addr} dev eth0
    ifconfig eth0 down
    brctl addbr br100
    brctl addif br100 eth0
    ifconfig eth0 up
    ifconfig br100 up ${addr}

    ifconfig -a
    ps auxw
}

function template_client() {
    # $1 - IP
    local ip=$1

    sed /etc/chef/client-template.rb -s -e s/@IP@/${ip}/ > /etc/chef/client.rb
}

function flush_iptables() {
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
}
