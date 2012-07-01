#!/bin/bash -x

# likely need overrides
CREDENTIALS=${CREDENTIALS:-./nova-credentials}
PRIVKEY=${PRIVKEY:-id_jenkins}
KEYNAME=${KEYNAME:-jenkins}
CHEF_IMAGE=${CHEF_IMAGE:-bca4f433-f1aa-4310-8e8a-705de63ca355}
INSTANCE_IMAGE=${INSTANCE_IMAGE:-fe9bbecf-60ee-4c92-a229-15a119570a87}
JOBID=${JOBID:-${RANDOM}}
CHEF_FLAVOR=${CHEF_FLAVOR:-2}
INSTANCE_FLAVOR=${INSTANCE_FLAVOR:-2}
SOURCE_DIR=${SOURCE_DIR:-$(readlink -f $(basename $0))

declare -A TYPEMAP
TYPEMAP[chef]=${CHEF_IMAGE}:${CHEF_FLAVOR}
TYPEMAP[infra]=${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}
TYPEMAP[kong]=${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}
TYPEMAP[swiftstorage]=${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}  # could be instance with large ephemeral
TYPEMAP[swiftproxy]=${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}

# sensible defaults
SPINDOWN_TIMEOUT=${SPINDOWN_TIMEOUT:-60}
SPINUP_TIMEOUT=${SPINUP_TIMEOUT:-60}
ACCESS_NETWORK=${ACCESS_NETWORK:-public}
SSH_TIMEOUT=${SSH_TIMEOUT:-240}

# currently running background tasks
declare -A PIDS=()
OPERANT_SERVER=""
declare -a FC_TASKS

function cleanup() {
    local retval=$?

    trap - ERR EXIT
    set +e

    echo "----------------- cleanup"

    for pid in ${!PIDS[@]}; do
        kill -TERM ${pid}
    done

    collect_tasks


    if [ -e ${TMPDIR}/nodes ]; then
        for d in ${TMPDIR}/nodes/*; do
            source ${d}
            background_task "terminate_server ${NODE_FRIENDLY_NAME}"
        done
    fi

    collect_tasks

    echo "Exiting with return value of ${retval}"
    exit ${retval}
}

function init() {
    trap cleanup ERR EXIT

    shopt -s nullglob
    set -e

    export TMPDIR=$(mktemp -d)
    mkdir -p ${TMPDIR}/nodes
    mkdir -p ${TMPDIR}/scripts
    source ${CREDENTIALS}
}

function terminate_server() {
    #1 - server name
    local name=${JOBID}-$1

    if nova show ${name}; then
        nova delete ${name}
    fi

    timeout ${SPINDOWN_TIMEOUT} sh -c "while nova show ${name} > /dev/null; do sleep 2; done"
}

function boot_and_wait() {
    # $1 - image
    # $2 - name
    # $3 - flavor
    local image=$1
    local name=${JOBID}-$2
    local flavor=$3
    local ip=""

    nova boot --flavor=${flavor} --image=${image} --key_name=${KEYNAME} ${name}

    local count=0

    while [ "$ip" = "" ] && (( count < 30 )); do
        sleep 2
        ip=$(nova show ${name} | grep "${ACCESS_NETWORK} network" | awk '{ print $5 }')
        count=$((count + 1))
    done

    [ -n "$ip" ]

    cat > ${TMPDIR}/nodes/${name} <<-EOF
    export NODE_NAME=${name}
    export NODE_FRIENDLY_NAME=${2}
    export NODE_IMAGE=${image}
    export NODE_KEY=${KEYNAME}
    export NODE_FLAVOR=${flavor}
    export NODE_IP=${ip}
EOF

    count=0
    while [ ! ACTIVE = $(nova show ${name} | grep status | awk '{print $4}') ] && (( count < $SPINUP_TIMEOUT )); do
        sleep 1
        count=$((count + 1))
    done

    [ $count -lt ${SPINUP_TIMEOUT} ]
}

function boot_cluster() {
    # $1... - cluster members in name:image:flavor format

    echo "------------------------------- KICKING CLUSTER"

    for host in "$@"; do
        declare -a hostinfo
        hostinfo=(${host//:/ })

        local name=${hostinfo[0]}
        local image=${hostinfo[1]}
        local flavor=${hostinfo[2]}

        background_task "boot_and_wait ${image} ${name} ${flavor}"
        echo "Booting ${hostinfo[0]} with image ${hostinfo[1]} and flavor ${hostinfo[2]} as pid $!"
    done

    collect_tasks
}

function ip_for_host() {
    # $1 - host
    [ -e ${TMPDIR}/nodes/${JOBID}-${1} ]

    source ${TMPDIR}/nodes/${JOBID}-${1}
    echo $NODE_IP
}

function wait_for_ssh() {
    # $1 - ip
    local ip=$1

    echo "--------------------------- WAITING FOR SSH ON ${ip}"
    timeout ${SSH_TIMEOUT} sh -c "while ! nc ${ip} 22 -w 1 -q 0 < /dev/null;do :; done"
    sleep 2
}

function wait_for_cluster_ssh() {
    echo "------------------------------- WAITING FOR CLUSTER SSH"
    for host in "$@"; do
        declare -a hostinfo
        hostinfo=(${host//:/ })

        local name=${hostinfo[0]}
        local ip=$(ip_for_host ${name})

        background_task "wait_for_ssh ${ip}"
    done

    collect_tasks
}

function background_task() {
#    eval "(exec 2>&1; exec 1>/tmp/$$; exec $1 )" &
#    exec "$@ &"
    outfile=$(mktemp)
    eval "$@ > ${outfile} 2>&1 &"
    PIDS["$!"]=${outfile}
}

function collect_tasks() {
    local failcount=0
    for pid in ${!PIDS[@]}; do
        echo "Waiting for pid ${pid}"
        wait $pid || failcount=$((failcount + 1))
        echo "Collected pid ${pid} with result code $?.  Output:"
        cat ${PIDS[$pid]}
        rm ${PIDS[$pid]}
    done

    PIDS=()
    [ $failcount -eq 0 ]
}

function prepare_chef() {
    # $1 - server
    local server=$1

    if [ ! -e ${TMPDIR}/chef/${server} ]; then
        mkdir -p ${TMPDIR}/chef/${server}/checksums
        cp ${SOURCE_DIR}/files/{chefadmin,validation}.pem ${TMPDIR}/chef/${server}
        cat > ${TMPDIR}/chef/${server}/knife.rb <<-EOF
            log_level                :info
            log_location             STDOUT
            node_name                "chefadmin"
            client_key               "${TMPDIR}/chef/${server}/chefadmin.pem"
            validation_client_name   "chef-validator"
            validation_key           "${TMPDIR}/chef/${server}/validation.pem"
            chef_server_url          "http://$(ip_for_host ${server}):4000"
            cache_type               'BasicFile'
            cache_options( :path => '/${TMPDIR}/chef/${server}/checksums' )
EOF
}

function create_chef_environment() {
    # $1 - server
    # $2 - environment name
    local server=$1
    local environment=$2

    prepare_chef ${server}

    local knife=${TMPDIR}/chef/${server}/knife.rb

    EDITOR=/bin/true knife create enironment ${environment} -c ${knife}
}

function role_add() {
    # $1 - chef server
    # $2 - node (friendly name)
    # $3 - role
}


function with_server() {
    OPERANT_SERVER=$1
}

function x_with_server() {
    OPERANT_SERVER=$1
    while read -r line; do
        fc_add_task ${line}
    done
}

function x_with_cluster() {
    local host

    fc_reset_tasks
    while read -r line; do
        fc_add_task ${line}
    done

    for host in "$@"; do
        declare -a hostinfo
        hostinfo=(${host//:/ })

        local name=${hostinfo[0]}

        OPERANT_SERVER=${name}
        background_task "fc_do"
    done

    collect_tasks
}

function fc_add_task() {
    FC_TASKS[${#FC_TASKS[@]}]="$@"
}

function fc_reset_tasks() {
    FC_TASKS=()
}

function fc_exec() {
    fc_add_task "$@"
}

function fc_install_package() {
    fc_add_task "install_package $@"
}

function fc_cd() {
    fc_add_task "cd $@"
}

function fc_do() {
    local ip=$(ip_for_host ${OPERANT_SERVER})
    local sshopts="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
    local user="ubuntu"

    cat fakeconfig.sh > ${TMPDIR}/scripts/${OPERANT_SERVER}.sh
    for action in "${FC_TASKS[@]}"; do
        echo $action >> ${TMPDIR}/scripts/${OPERANT_SERVER}.sh
    done

    cat ${TMPDIR}/scripts/${OPERANT_SERVER}.sh

    scp -i ${PRIVKEY} ${sshopts} ${TMPDIR}/scripts/${OPERANT_SERVER}.sh ${user}@${ip}:/tmp/fakeconfig.sh
    ssh -i ${PRIVKEY} ${sshopts} ${user}@${ip} "sudo /bin/bash -x /tmp/fakeconfig.sh"

    fc_reset_tasks
}


init

declare -a cluster
cluster=(
    "nova-aio:${INSTANCE_IMAGE}:${INSTANCE_FLAVOR}"
)

boot_and_wait ${CHEF_IMAGE} chef-server ${CHEF_FLAVOR}
wait_for_ssh $(ip_for_host chef-server)

x_with_server "chef-server" <<EOF
apt-get update
install_package git-core
rabbitmq_fixup oociahez
checkout_cookbooks
upload_cookbooks
upload_roles
EOF
background_task "fc_do"

boot_cluster ${cluster[@]}
wait_for_cluster_ssh ${cluster[@]}

# at this point, chef server is done, cluster is up.
# let's set up the environment.
create_chef_environment chef-server jenkins-test

# Move the validation.pem over to the clients so they
# can register

# this is kind of sloppy and non-obvious
x_with_cluster ${cluster[@]} <<EOF
install_chef_client
cat > /etc/chef/validation.pem <<EOF1

EOF1
EOF




# echo  "Done waiting for cluster ssh"

# knife cookbook upload -a o cookbooks
# EOF
# background_task "fc_do"

# x_with_cluster ${cluster[@]} <<EOF
# apt-get update
# EOF
