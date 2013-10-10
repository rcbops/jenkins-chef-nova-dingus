#!/usr/bin/env bash


START_TIME=$(date +%s)
CHEF_IMAGE=chef-template5
JOB_NAME="spc"
source $(dirname $0)/chef-jenkins.sh

print_banner "Initializing Job"
init

CHEF_ENV="swift-private-cloud"
print_banner "Build Parameters
~~~~~~~~~~~~~~~~
environment = ${CHEF_ENV}
INSTANCE_IMAGE=${INSTANCE_IMAGE}
AVAILABILITY_ZONE=${AZ}
TMPDIR = ${TMPDIR}
GIT_PATCH_URL = ${GIT_PATCH_URL}"

rm -rf logs
mkdir -p logs/run
exec 9>logs/run/out.log
BASH_XTRACEFD=9
set -x
GIT_REPO=${GIT_REPO:-swift-lite}
declare -a cluster
cluster=(admin1 proxy1 storage1 storage2 storage3) # order sensitive

start_timer
setup_quantum_network
stop_timer

start_timer
print_banner "creating chef server"
boot_and_wait chef-server
wait_for_ssh chef-server
stop_timer

start_timer
x_with_server "Fixing up the chef-server and booting the cluster" "chef-server" <<EOF
set_package_provider
update_package_provider
flush_iptables
run_twice install_package git-core
fixup_hosts_file_for_quantum
chef11_fixup
#run_twice checkout_cookbooks
run_twice install_package ruby1.9.3 libxml2-dev libxslt-dev build-essential libz-dev
mkdir /root/cookbooks
git clone http://github.com/rcbops-cookbooks/swift-lite /root/cookbooks/swift-lite
git clone http://github.com/rcbops-cookbooks/swift-private-cloud /root/cookbooks/swift-private-cloud
pushd "/root/cookbooks/${GIT_REPO}"
if [[ -n "${GIT_PATCH_URL}" ]] && ! ( curl -s ${GIT_PATCH_URL} | git apply -v); then
    echo "Unable to merge proposed patch: ${GIT_PATCH_URL}"
    exit 1
fi
popd
EOF
background_task "fc_do"

boot_cluster ${cluster[@]}
stop_timer

start_timer
print_banner "Waiting for IP connectivity to the instances"
wait_for_cluster_ssh ${cluster[@]}
print_banner "Waiting for SSH to become available"
wait_for_cluster_ssh_key ${cluster[@]}
stop_timer

start_timer
x_with_server "uploading the cookbooks" "chef-server" <<EOF
#run_twice upload_cookbooks
#run_twice upload_roles
run_twice upload_roles /root/cookbooks/swift-lite/contrib/roles
run_twice upload_roles /root/cookbooks/swift-private-cloud/roles
cd /root/cookbooks/swift-private-cloud
gem install berkshelf
berks install
berks upload
knife cookbook upload --force -o "/root/cookbooks" "${GIT_REPO}"
EOF
background_task "fc_do"

x_with_cluster "Cluster booted.  Setting up the package providers and vpn thingy..." ${cluster[@]} <<EOF
plumb_quantum_networks eth1
# set_quantum_network_link_up eth2
cleanup_metadata_routes eth0 eth1
fixup_hosts_file_for_quantum
wait_for_rhn
set_package_provider
update_package_provider
run_twice install_package bridge-utils
EOF
stop_timer

start_timer
print_banner "Setting up the chef environment"
# at this point, chef server is done, cluster is up.
# let's set up the environment.
create_chef_environment chef-server swift-private-cloud
stop_timer

# add_chef_clients chef-server ${cluster[@]} # what does this do?

start_timer
x_with_cluster "Installing chef-client and running for the first time" proxy1 storage{1..3} admin1 <<EOF
flush_iptables
install_chef_client
chef11_fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client
EOF
stop_timer

# not strictly necessary, as this is done on the client side
for host in ${cluster[@]}; do
    new_env="swift-private-cloud"
    set_node_attribute chef-server ${host} "chef_environment" "\"${new_env}\""
done

set_environment_attribute chef-server swift-private-cloud "override_attributes/swift-private-cloud/keystone/swift_admin_url" "\"http://$(ip_for_host proxy1):8080/v1/AUTH_%(tenant_id)s\""
set_environment_attribute chef-server swift-private-cloud "override_attributes/swift-private-cloud/keystone/swift_internal_url" "\"http://$(ip_for_host proxy1):8080/v1/AUTH_%(tenant_id)s\""
set_environment_attribute chef-server swift-private-cloud "override_attributes/swift-private-cloud/keystone/swift_public_url" "\"http://$(ip_for_host proxy1):8080/v1/AUTH_%(tenant_id)s\""

role_add chef-server admin1 "role[spc-starter-controller]"

x_with_cluster "installing admin node" admin1 <<EOF
chef-client
EOF

role_add chef-server proxy1 "role[spc-starter-proxy]"

for storage in storage{1..3}; do
        role_add chef-server ${storage} "role[spc-starter-storage]"
done

x_with_cluster "installing swifteses" proxy1 storage{1..3} <<EOF
chef-client
EOF

# TODO (wilk): test actual swift private cloud helpers and so on
# on the proxy, build up some rings.
x_with_server "three rings for the elven kings" admin1 <<EOF
cd /etc/swift

swift-ring-builder object.builder create 8 3 0
swift-ring-builder container.builder create 8 3 0
swift-ring-builder account.builder create 8 3 0

swift-ring-builder object.builder add z1-$(ip_for_host storage1):6000/disk1 100
swift-ring-builder object.builder add z2-$(ip_for_host storage2):6000/disk1 100
swift-ring-builder object.builder add z3-$(ip_for_host storage3):6000/disk1 100

swift-ring-builder container.builder add z1-$(ip_for_host storage1):6001/disk1 100
swift-ring-builder container.builder add z2-$(ip_for_host storage2):6001/disk1 100
swift-ring-builder container.builder add z3-$(ip_for_host storage3):6001/disk1 100

swift-ring-builder account.builder add z1-$(ip_for_host storage1):6002/disk1 100
swift-ring-builder account.builder add z2-$(ip_for_host storage2):6002/disk1 100
swift-ring-builder account.builder add z3-$(ip_for_host storage3):6002/disk1 100

swift-ring-builder object.builder rebalance
swift-ring-builder container.builder rebalance
swift-ring-builder account.builder rebalance

chown -R swift: .
mkdir -p /tmp/rings
cp {account,object,container}.ring.gz /tmp/rings

chown -R ubuntu: /tmp/rings

exit 0
EOF

background_task "fc_do"

# ... and in parallel, format the drives and mount
x_with_cluster "Fixing up swift disks... under the sky" storage{1..3} <<EOF
install_package xfsprogs
unmount_filesystem /mnt
parted -s /dev/vdb mklabel msdos
parted -s /dev/vdb mkpart primary xfs 1M 100%
mkfs.xfs -f -i size=512 /dev/vdb1
mkdir -p /srv/node/disk1
mount /dev/vdb1 /srv/node/disk1 -o noatime,nodiratime,nobarrier,logbufs=8
chown -R swift: /srv/node/disk1
EOF

mkdir -p ${TMPDIR}/rings
fetch_file admin1 "/tmp/rings/*.ring.gz" ${TMPDIR}/rings

x_with_cluster "copying ring data" storage{1..3} proxy1 <<EOF
copy_file ${TMPDIR}/rings/account.ring.gz /etc/swift
copy_file ${TMPDIR}/rings/container.ring.gz /etc/swift
copy_file ${TMPDIR}/rings/object.ring.gz /etc/swift
chown -R swift: /etc/swift
EOF

# now start all the services
x_with_cluster "starting services" storage{1..3} proxy1 <<EOF
chef-client
EOF
fc_do

x_with_server "Finalizing install by running chef on admin1" admin1 <<EOF
sleep 10
chef-client
EOF
fc_do

cat > ${TMPDIR}/config.ini <<EOF2
[KongRequester]
auth_url = http://$(ip_for_host admin1):5000
user = admin
password = secrete
tenantname = admin
region = RegionOne
EOF2


# install kong and exerstack and do the thangs
x_with_server "Installing kong and exerstack" admin1 <<EOF
cd /root
install_package git
git clone https://github.com/rcbops/kong /root/kong
git clone https://github.com/rcbops/exerstack /root/exerstack

cat > /root/exerstack/localrc <<EOF2
export SERVICE_HOST=$(ip_for_host admin1)
export NOVA_PROJECT_ID=admin
export OS_AUTH_URL=http://$(ip_for_host admin1):5000/v2.0
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=secrete
export OS_AUTH_STRATEGY=keystone
export OS_REGION_NAME=RegionOne
export OS_VERSION=2.0
EOF2

copy_file ${TMPDIR}/config.ini /root/kong/etc

EOF
fc_do

# running tests
x_with_server "Running tests on admin1" admin1 <<EOF

pushd /root/exerstack
./exercise.sh grizzly swift.sh
popd


pushd /root/kong
ONESHOT=1 ./run_tests.sh -V --version grizzly --swift --keystone
popd

# verify swiftops user can dsh to all nodes
if [[ -e "/etc/redhat-release" ]]; then
    su swiftops -c "pdsh -g swift hostname" | wc -l | grep ^$[ ${#cluster[@]} - 1 ]
else
    su swiftops -c "dsh -Mcg swift hostname" | wc -l | grep ^$[ ${#cluster[@]} - 1 ]
fi

# verify swift-recon works
swift-recon --md5  | grep '^3/3 hosts matched'

# verify dispersion reports are configured
swift-dispersion-populate
swift-dispersion-report | grep '100.00%' | grep '6 of 6'

# verify ntp is configured on all nodes
num_ntpclients="\$(echo 'monlist' | ntpdc  | grep 192.168 | wc -l)"
if [[ "\$num_ntpclients" -ne 4 ]]; then
    echo "Expected 4 ntp clients on 192.168 network, found \${num_ntpclients}" 1>&2
    exit 1
fi

# verify syslog is configured to log to admin node
if [[ -e "/etc/redhat-release" ]]; then
    su swiftops -c "pdsh -g swift sudo swift-init all restart"
else
    su swiftops -c "dsh -Mcg swift sudo swift-init all restart"
fi

if [[ "\$(ls /var/log/swift | wc -l)" -lt 5 ]]; then
   echo "Expecting at least five files in /var/log/swift" 1>&2
   exit 1
fi

# verify mail configuration


# verify object expirer is running on admin node
if [[ "\$(pgrep -f object-expirer | wc -l)" -eq 0 ]]; then
   echo "Swift object expirer is not running on admin node" 1>&2
   exit 1
fi
EOF

fc_do

echo "Done"
