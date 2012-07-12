#!/bin/bash -x

# likely need overrides
CREDENTIALS=${CREDENTIALS:-./nova-credentials}
CHEF_IMAGE=${CHEF_IMAGE:-bca4f433-f1aa-4310-8e8a-705de63ca355}
INSTANCE_IMAGE=${INSTANCE_IMAGE:-fe9bbecf-60ee-4c92-a229-15a119570a87}
JOBID=${JOBID:-${RANDOM}}
CHEF_FLAVOR=${CHEF_FLAVOR:-2}
INSTANCE_FLAVOR=${INSTANCE_FLAVOR:-2}
SOURCE_DIR=${SOURCE_DIR:-$(dirname $(readlink -f $0))}
PRIVKEY=${PRIVKEY:-${SOURCE_DIR}/files/id_jenkins}
KEYNAME=${KEYNAME:-jenkins}

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
OPERANT_TASK=""
declare -a FC_TASKS

function cleanup() {
    local retval=$?

    trap - ERR EXIT
    set +e

    echo "----------------- cleanup"

    for pid in ${!PIDS[@]}; do
        kill -TERM ${pid}
    done

    collect_tasks viciously


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

    if [ ${DEBUG:-0} -eq 1 ]; then
        set -x
    fi

    shopt -s nullglob

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

    echo "Booting ${name} with image ${image} using flavor ${flavor} on PID $$"
    nova boot --flavor=${flavor} --image=${image} --key_name=${KEYNAME} ${name} > /dev/null 2>&1

    local count=0

    while [ "$ip" = "" ] && (( count < 30 )); do
        sleep 2
        ip=$(nova show ${name} | grep "${ACCESS_NETWORK} network" | awk '{ print $5 }')
        if [ "$ip" = "|" ]; then
            ip=""
        fi
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
    while [ ! ACTIVE = $(nova show ${name} | grep status | awk '{print $4}') ] && (( count < ${SPINUP_TIMEOUT} )); do
        sleep 1
        count=$((count + 1))
    done

    [ ${count} -lt ${SPINUP_TIMEOUT} ]
}

function boot_cluster() {
    # $1... - cluster members in name:image:flavor format

    for host in "$@"; do
        declare -a hostinfo
        hostinfo=(${host//:/ })

        local name=${hostinfo[0]}
        local image=${hostinfo[1]}
        local flavor=${hostinfo[2]}

        background_task "boot_and_wait ${image} ${name} ${flavor}"
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

    timeout ${SSH_TIMEOUT} sh -c "while ! nc ${ip} 22 -w 1 -q 0 < /dev/null > /dev/null;do :; done"
    sleep 2
}

function wait_for_cluster_ssh() {
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
    outfile=$(mktemp)
    exec 99>&1
    eval "$@ > ${outfile} 2>&1 &"
    local pid=$!
    echo "Backgrounded $@ as PID ${pid}" >&99
    exec 99>&-
    PIDS["${pid}"]=${outfile}
}

# Passing any argument disables the output printing
function collect_tasks() {
    local failcount=0
    local result=0
    local oldtrap=""

    echo "Collecting background tasks..."
    # allow a recently started task to schedule
    sleep 1

    for pid in ${!PIDS[@]}; do
        oldtrap=$(trap -p ERR)
        trap - ERR

        wait $pid
        result=$?

        eval "${oldtrap}"
        echo "Collected pid ${pid} with result code ${result}."

        if [ ${result} -ne 0 ]; then
            failcount=$(( failcount + 1 ))
        fi

        if [ ${result} -ne 0 ] || [ ${DEBUG:-0} -ne 0 ]; then
            if [ -z $1 ]; then  # don't show this if we passed an argument (final cleanup)
                echo "Output: "
                cat ${PIDS[$pid]}
            fi
        fi

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
    fi
}

function create_chef_environment() {
    # $1 - server
    # $2 - environment name
    local server=$1
    local environment=$2

    prepare_chef ${server}

    local knife=${TMPDIR}/chef/${server}/knife.rb

    EDITOR=/bin/true knife environment from file ${SOURCE_DIR}/files/${environment}.json -c ${knife}
}

function set_environment() {
    # $1 - chef server
    # $2 - node (friendly name)
    # $3 - environment name
    local server=$1
    local node=$2
    local environment=$3

    prepare_chef ${server}
    local knife=${TMPDIR}/chef/${server}/knife.rb

    local full_node_name=${JOBID}-${node}
    local chef_node_name=$(knife node list -c ${knife} | grep ${full_node_name} | head -n1 | awk '{ print $1 }')

    echo "Setting ${node} to environment ${environment}"

#    knife node show ${chef_node_name} -c ${knife}
    knife node show ${chef_node_name} -fj -c ${knife} > ${TMPDIR}/${chef_node_name}.json
    sed -i -e "s/_default/${environment}/" ${TMPDIR}/${chef_node_name}.json
    sed -i -e 's/^{$/{"json_class": "Chef::Node",/' ${TMPDIR}/${chef_node_name}.json
    EDITOR=/bin/true knife node from file ${TMPDIR}/${chef_node_name}.json -c ${knife}
#    knife node show ${chef_node_name} -c ${knife}
}

function run_tests() {
    # $1 - exerstack/kong server
    # $2 - version/component

    local server=$1
    local version=$2

    x_with_server "running tests" $1 <<-EOF
        cd /opt/kong
        ./run_tests.sh --version ${version} --nova

        cd /opt/exerstack
        ./exercise.sh ${version} euca.sh glance.sh keystone.sh nova-cli.sh
EOF

    fc_do
}


function role_add() {
    # $1 - chef server
    # $2 - node (friendly name)
    # $3 - role
    local server=$1
    local node=$2
    local role=$3

    prepare_chef ${server}
    local knife=${TMPDIR}/chef/${server}/knife.rb

    full_node_name=${JOBID}-${node}
    chef_node_name=$(knife node list -c ${knife} | grep ${full_node_name} | head -n1 | awk '{ print $1 }')

    echo "Adding role ${role} to ${chef_node_name}"

    knife node run_list add ${chef_node_name} "${role}" -c ${knife} > /dev/null
}

function x_with_server() {
    OPERANT_SERVER=$2
    fc_reset_tasks
    OPERANT_TASK=$1

    echo "Creating fc_do task for ${OPERANT_TASK}"
    while read -r line; do
        fc_add_task ${line}
    done
}

function x_with_cluster() {
    local host
    declare -a tasks
    local task_description="$1"
    shift

    echo "Running cluster task \"${task_description}\""
    tasks=()

    while read -r line; do
        tasks[${#tasks[@]}]="${line}"
    done

    for host in "$@"; do
        declare -a hostinfo
        hostinfo=(${host//:/ })

        local name=${hostinfo[0]}
        local task

        OPERANT_SERVER=${name}
        fc_reset_tasks
        fc_describe_task "${task_description}"
        for task in "${tasks[@]}"; do
            fc_add_task ${task}
        done

        echo "Preparing to run fc_do '${OPERANT_TASK}' on ${OPERANT_SERVER}"
        background_task "fc_do"
    done

    collect_tasks
    echo "Cluster task \"${task_description}\" done"
}

function fc_add_task() {
    if [ "$1" == "copy_file" ]; then
        if [ -e "${SOURCE_DIR}/files/$2" ]; then
            mkdir -p ${TMPDIR}/dirtree/${OPERANT_SERVER}
            cp ${SOURCE_DIR}/files/$2 ${TMPDIR}/dirtree/${OPERANT_SERVER}
        fi
    fi

    FC_TASKS[${#FC_TASKS[@]}]="$@"
}

function fc_reset_tasks() {
    FC_TASKS=()
    OPERANT_TASK="Unknown task"
    rm -rf ${TMPDIR}/dirtree/${OPERANT_SERVER}
}

function fc_describe_task() {
    OPERANT_TASK=${1:-Unknown Task}
}

function fc_do() {
    local ip=$(ip_for_host ${OPERANT_SERVER})
    local sshopts="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
    local user="ubuntu"

    echo "fc_do: executing task ${OPERANT_TASK} for server ${OPERANT_SERVER} as PID $$"

    cat fakeconfig.sh > ${TMPDIR}/scripts/${OPERANT_SERVER}.sh
    for action in "${FC_TASKS[@]}"; do
        echo $action >> ${TMPDIR}/scripts/${OPERANT_SERVER}.sh
    done

    cat ${TMPDIR}/scripts/${OPERANT_SERVER}.sh

    scp -i ${PRIVKEY} ${sshopts} ${TMPDIR}/scripts/${OPERANT_SERVER}.sh ${user}@${ip}:/tmp/fakeconfig.sh

    # copy over the template files.  Should be using rsync over ssh
    if [ -e "${TMPDIR}/dirtree/${OPERANT_SERVER}" ]; then
        echo "Files in dirtree:"
        ls ${TMPDIR}/dirtree/${OPERANT_SERVER}
        ssh -i ${PRIVKEY} ${sshopts} ${user}@${ip} "mkdir /tmp/fakeconfig"
        scp -i ${PRIVKEY} ${sshopts} ${TMPDIR}/dirtree/${OPERANT_SERVER}/* ${user}@${ip}:/tmp/fakeconfig
    fi

    ssh -i ${PRIVKEY} ${sshopts} ${user}@${ip} "sudo /bin/bash -x /tmp/fakeconfig.sh"
    retval=$?

    fc_reset_tasks
    return ${retval}
}
