#!/bin/bash

set -u
set -e
set -x

PLATFORM=debian
COOKBOOK_PATH=/root

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
    # $1 password
    if (! rabbitmqctl list_vhosts | grep -q chef ); then
        rabbitmqctl add_vhost /chef
        rabbitmqctl add_user chef ${1}
        rabbitmqctl set_permissions -p /chef chef ".*" ".*" ".*"
    fi
}

function checkout_cookbooks() {
    cd ${COOKBOOK_PATH}
    git clone https://github.com/rcbops/chef-cookbooks
    cd chef-cookbooks
    git checkout sprint
    git submodule init
    git submodule update
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

function copy_file() {
    # $1 - file name
    # $2 - local path
    local file=$1
    local path=$2

    mkdir -p $(dirname ${path})
    cp /tmp/fakeconfig/${file} ${path}
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
