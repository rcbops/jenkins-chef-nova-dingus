#!/bin/bash

set -e
set -x

PLATFORM=debian
COOKBOOK_PATH=/root

if [ -e /etc/redhat-release ]; then
    PLATFORM=redhat
else
    apt-get update
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

    case platform in
        debian|ubuntu)
            extra_packages="wget curl build-essential automake cgroup-lite"
            ;;
        redhat|fedora|centos|scientific)
            extra_packages="wget tar"
            ;;
    esac

    install_package ${extra_packages}

    if [ platform == "debian" ] || [ platform == "ubuntu" ]; then
        /usr/bin/cgroups-mount  # ?
    fi

    curl -skS http://s3.amazonaws.com/opscode-full-stack/install.sh | /bin/bash &
    wait $!
}



function register_client() {
    # $1 - Server IP
    # $2 - Environment name

    mkdir -p /etc/chef


}
