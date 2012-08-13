#!/bin/bash -x

# set up a job-id to be something other than random
# particularly if we're running under jenkins
JOBID=${JOB_NAME:-$(basename $0 .sh)}_${BUILD_NUMBER:-${USER}-${RANDOM}}
JOBID=$(echo -n ${JOBID,,} | tr -c "a-z0-9" "-")

# likely need overrides
CHEF_IMAGE=${CHEF_IMAGE:-bca4f433-f1aa-4310-8e8a-705de63ca355}
INSTANCE_IMAGE=${INSTANCE_IMAGE:-fe9bbecf-60ee-4c92-a229-15a119570a87}
CHEF_FLAVOR=${CHEF_FLAVOR:-2}
INSTANCE_FLAVOR=${INSTANCE_FLAVOR:-2}
SOURCE_DIR=${SOURCE_DIR:-$(dirname $(readlink -f $0))}
CREDENTIALS=${CREDENTIALS:-${SOURCE_DIR}/files/nova-credentials}
PRIVKEY=${PRIVKEY:-${SOURCE_DIR}/files/id_jenkins}
KEYNAME=${KEYNAME:-jenkins}
USE_CS=${USE_CS:-0}
BEST_MIRROR=""
if [ ${USE_CS} -eq 1 ]; then
    LOGIN=${LOGIN:-root}
    SPINUP_TIMEOUT=600
else
    LOGIN=${LOGIN:-ubuntu}
fi
NOCLEAN=${NOCLEAN:-0}
DEPLOY=${DEPLOY:-0}
GITHUB_CREDENTIALS="${GITHUB_CREDENTIALS:-${SOURCE_DIR}/files/github-credentials}"

declare -A TYPEMAP
TYPEMAP[chef]=${CHEF_IMAGE}:${CHEF_FLAVOR}

# sensible defaults
SPINDOWN_TIMEOUT=${SPINDOWN_TIMEOUT:-60}
SPINUP_TIMEOUT=${SPINUP_TIMEOUT:-60}
ACCESS_NETWORK=${ACCESS_NETWORK:-public}
SSH_TIMEOUT=${SSH_TIMEOUT:-240}

# currently running background tasks
declare -A PIDS=()
OPERANT_SERVER=""
OPERANT_TASK=""
PARENT_PID=$$
declare -a FC_TASKS

# setting the NOCLEAN variable to non-zero will not clean up
# instances if it exited in failure.
#
# setting DEPLOY to non-zero will not clean up instances
# in any situation
#
function cleanup() {
    local retval=$?

    trap - ERR EXIT
    set +e

    echo "----------------- cleanup"

    for pid in ${!PIDS[@]}; do
        if kill -0 ${pid}; then
            kill -TERM ${pid}
        fi
    done

    collect_tasks viciously

    # only leave this on error with noclean set
    if [ ${NOCLEAN} -eq 0 ] || [ ${retval} -eq 0 ]; then
        if [ -e ${TMPDIR}/nodes ]; then
            for d in ${TMPDIR}/nodes/*; do
                source ${d}
                if [ ${DEPLOY} -ne 1 ]; then
                    background_task "terminate_server ${NODE_FRIENDLY_NAME}"
                fi
            done
        fi
        collect_tasks
    fi

    echo "Exiting with return value of ${retval}"
    exit ${retval}
}

function init() {
    trap cleanup ERR EXIT TERM INT
    shopt -s nullglob
#    shopt -s extdebug # inherit trap handlers
    set -o errtrace

    echo "Intializing job ${JOBID}"

    # convenient place to store credentials.  Assume it builds
    # an array called MISC_CREDENTIALS, with keys being
    # [service_user]=password
    #
    if [ -e ${SOUCE_DIR}/files/credentials ]; then
        source ${SOURCE_DIR}/files/credentials
    fi

    # fix up for cloud servers-ng
    if ( grep -q "identity.api.rackspacecloud" ${CREDENTIALS} ); then
        USE_CS=1
        LOGIN=root
        SPINUP_TIMEOUT=600
    fi

    if [ ${DEBUG:-0} -eq 1 ]; then
        set -x
    fi


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

# given an image that's either a UUID or a name, find the
# UUID for it
function translate_image() {
    # $1 - image or uuid
    #
    # returns _RET set with the UUID

    local image=$1

    local candidates=$(nova image-list | grep "${image}" | awk '{ print $2 }')

    if [ $(echo "${candidates}" | wc -l) -ne 1 ] || [ -z "${candidates}" ]; then
        echo "Can't locate image ${image} -- image does not exist or too many candidates"
        return 1
    fi

    _RET=${candidates}
}

function boot_and_wait() {
    # $1 - name
    # $2 - image
    # $3 - flavor
    local name=${JOBID}-$1
    local ip=""
    local extra_flags=""
    local friendly_name=$1

    get_likely_flavors ${friendly_name}

    local image=${2:-${LIKELY_IMAGE}}
    local flavor=${3:-${LIKELY_FLAVOR}}

    # if the image isn't uuid-ey, then we'll grep around for the
    # image id.
    translate_image "${image}"
    image=$_RET

    echo "Booting ${name} with image ${image} using flavor ${flavor} on PID $$"
    if [ $USE_CS -eq 0 ]; then
        extra_flags="--key_name=${KEYNAME}"
    else
        extra_flags="--file /root/.ssh/authorized_keys=${SOURCE_DIR}/files/authorized_keys"
        LOGIN="root"
    fi

    nova boot --flavor=${flavor} --image=${image} ${extra_flags} ${name} > /dev/null 2>&1

    local count=0

    while [ "$ip" = "" ] && (( count < 30 )); do
        sleep 2

        ip=$(nova show ${name} | grep "${ACCESS_NETWORK} network" | cut -d'|' -f3 | tr -d ' ' | tr , '\n' | egrep '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)

        if [ "$ip" = "|" ]; then
            ip=""
        fi
        count=$((count + 1))
    done

    [ -n "$ip" ]

    cat > ${TMPDIR}/nodes/${name} <<-EOF
    export NODE_NAME=${name}
    export NODE_FRIENDLY_NAME=${friendly_name}
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

    if [ ${count} -lt ${SPINUP_TIMEOUT} ]; then
        return 0
    fi
    return 1
}


function github_post_comment() {
    # $1 - git comment url
    # $2... - body

    local comment_url=${1:-}
    shift
    local body="$@"

    if [ ! -e ${GITHUB_CREDENTIALS} ]; then
        echo "No github credentials -- not posting comment"
        return 0
    fi

#curl -s -K ~/.rcbjenkins-git-creds ${GIT_COMMENT_URL} -X 'POST' -d '{"body": "Gate: Nova All-In-One\n * '${BUILD_URL}'consoleFull : SUCCESS"}'

    curl -s -K ${GITHUB_CREDENTIALS} ${comment_url} -X 'POST' -d '{"body": ${body} }'

}

function get_likely_flavors() {
    # $1 - hostname

    # look up in a typemap first.  If there is
    # no typemap, and it looks chefish, use the chef
    # instance and flavor, otherwise use the instance

    LIKELY_FLAVOR=${INSTANCE_FLAVOR}
    LIKELY_IMAGE=${INSTANCE_IMAGE}

    local hostname=$1

    if [ "${TYPEMAP[${hostname}]:-}" == "" ]; then
        if [[ ${hostname} =~ "chef" ]]; then
            LIKELY_FLAVOR=${CHEF_FLAVOR}
            LIKELY_IMAGE=${CHEF_IMAGE}
        fi
    else
        local flavor_info=(${TYPEMAP[${hostname}]//:/ })
        LIKELY_IMAGE=${flavor_info[0]}
        LIKELY_FLAVOR=${flavor_info[1]}
    fi
}


function boot_cluster() {
    # $1... - cluster members in name:image:flavor format

    for host in "$@"; do
        declare -a hostinfo
        hostinfo=(${host//:/ })

        local name=${hostinfo[0]}
        local image=${hostinfo[1]}
        local flavor=${hostinfo[2]}

        background_task "boot_and_wait \"${name}\" \"${image}\" \"${flavor}\""
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

    eval "$* > ${outfile} 2>&1 &"
    local pid=$!
    echo "Backgrounded $@ as PID ${pid}" >&99
    exec 99>&-
    PIDS["${pid}"]=${outfile}
}

# Passing any argument disables the output printing
function collect_tasks() {
    local failcount=0
    local result=0
    local start_time=$(date +%s)
    local stop_time=start_time
    local oldtrap

    echo "Collecting background tasks..."

    # allow a recently started task to schedule
    sleep 1

    for pid in ${!PIDS[@]}; do
        # turn off error traps while we wait for the pid
        oldtrap=$(trap -p ERR)
        trap - ERR

        result=0
        wait $pid > /dev/null 2>&1
        result=$?

        eval ${oldtrap}

        stop_time=$(date +%s)
        local elapsed_time=$(( stop_time - start_time ))
        echo "Collected pid ${pid} with result code ${result} in ${elapsed_time} seconds."

        if [ ${result} -ne 0 ]; then
            failcount=$(( failcount + 1 ))
        fi

        if [ ${result} -ne 0 ] || [ ${DEBUG:-0} -ne 0 ]; then
            if [ -z ${1:-} ] || [ $failcount -gt 1 ]; then  # only show first
                echo "Output: "
                cat ${PIDS[$pid]}
            fi
        fi

        rm ${PIDS[$pid]}
    done

    stop_time=$(date +%s)
    local elapsed_time=$(( stop_time - start_time ))

    echo "Collected all background tasks in ${elapsed_time} seconds with ${failcount} failures"

    PIDS=()
    return ${failcount}
}

function prepare_chef() {
    # $1 - server
    local server=$1

    if [ ! -e ${TMPDIR}/chef/${server} ]; then
        mkdir -p ${TMPDIR}/chef/${server}/checksums
        wget -nv http://$(ip_for_host ${server}):4000/validation.pem -O ${TMPDIR}/chef/${server}/validation.pem
        wget -nv http://$(ip_for_host ${server}):4000/chefadmin.pem -O ${TMPDIR}/chef/${server}/chefadmin.pem

        # cp ${SOURCE_DIR}/files/{chefadmin,validation}.pem ${TMPDIR}/chef/${server}
        cat > ${TMPDIR}/chef/${server}/knife.rb <<-EOF
            log_level                :info
            log_location             "/tmp/foo.txt"
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
    # $2 - environment file
    local server=$1
    local environment=$2

    local environment_source=${SOURCE_DIR}/files/${environment}.json

    if [ ! -e ${environment_source} ]; then
        environment_source=${environment}
        if [ ! -e ${environment_source} ]; then
            echo "Can't find environment ${environment}"
            return 1
        fi
    fi

    prepare_chef ${server}

    local knife=${TMPDIR}/chef/${server}/knife.rb

    EDITOR=/bin/true knife environment from file ${environment_source} -c ${knife}
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
    # $3.. - nova/glance/keystone/swift

    local server=$1
    local version=$2

    shift; shift

    declare -A exerstacktests
    declare -A kongtests

    exerstacktests=(
        [nova]="euca.sh nova-cli.sh"
        [glance]="glance.sh"
        [keystone]="keystone.sh"
        [swift]="swift.sh"
    )

    kongtests=(
        [nova]="--nova"
        [swift]="--swift"
    )

    local exerstack_tests=""
    local kong_tests=""

    for d in "$@"; do
        exerstack_tests+="${exerstacktests[${d}]:-} "
        kong_tests+="${kongtests[${d}]:-} "
    done

    x_with_server "running tests" ${server} <<-EOF
        cd /opt/exerstack
        ONESHOT=1 ./exercise.sh ${version} ${exerstack_tests}

        cd /opt/kong
        ./run_tests.sh --version ${version} ${kong_tests}
EOF
    fc_do
}

function set_node_attribute() {
    # $1 chef server
    # $2 node
    # $3 key
    # $4 value

    local server=$1
    local node=$2
    local key=$3
    local value=$4

    local knife=${TMPDIR}/chef/${server}/knife.rb

    local full_node_name=${JOBID}-${node}
    local chef_node_name=$(knife node list -c ${knife} | grep ${full_node_name} | head -n1 | awk '{ print $1 }')

    knife node show ${chef_node_name} -fj -c ${knife} > ${TMPDIR}/${chef_node_name}.json
    ${SOURCE_DIR}/files/jsoncli.py -s "${key}=${value}"  -s 'json_class="Chef::Node"' ${TMPDIR}/${chef_node_name}.json > ${TMPDIR}/${chef_node_name}-new.json
    knife node from file -c ${knife} ${TMPDIR}/${chef_node_name}-new.json
}

function set_environment_attribute() {
    # $1 chef server
    # $2 environment name
    # $3 key
    # $4 value

    local server=$1
    local environment=$2
    local key=$3
    local value=$4

    local knife=${TMPDIR}/chef/${server}/knife.rb

    knife environment show ${environment} -fj -c ${knife} > ${TMPDIR}/env-${environment}.json
    ${SOURCE_DIR}/files/jsoncli.py -s "${key}=${value}" ${TMPDIR}/env-${environment}.json > ${TMPDIR}/env-${environment}-new.json
    knife environment from file -c ${knife} ${TMPDIR}/env-${environment}-new.json
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
    local user=${LOGIN}
    local var

    echo "fc_do: executing task ${OPERANT_TASK} for server ${OPERANT_SERVER} as PID $$"

    cat ${SOURCE_DIR}/files/fakeconfig.sh > ${TMPDIR}/scripts/${OPERANT_SERVER}.sh

    # pass through important environment vars.  This should
    # be configurable, but isn't.
    for var in COOKBOOK_OVERRIDE GIT_PATCH_URL GIT_REPO GIT_DIFF_URL; do
        echo "${var}=${!var}" >> ${TMPDIR}/scripts/${OPERANT_SERVER}.sh
    done

    for action in "${FC_TASKS[@]}"; do
        echo $action >> ${TMPDIR}/scripts/${OPERANT_SERVER}.sh
    done

    # cat ${TMPDIR}/scripts/${OPERANT_SERVER}.sh

    scp -i ${PRIVKEY} ${sshopts} ${TMPDIR}/scripts/${OPERANT_SERVER}.sh ${user}@${ip}:/tmp/fakeconfig.sh

    # copy over the template files.  Should be using rsync over ssh
    if [ -e "${TMPDIR}/dirtree/${OPERANT_SERVER}" ]; then
        ssh -i ${PRIVKEY} ${sshopts} ${user}@${ip} "mkdir /tmp/fakeconfig"
        scp -i ${PRIVKEY} ${sshopts} ${TMPDIR}/dirtree/${OPERANT_SERVER}/* ${user}@${ip}:/tmp/fakeconfig
    fi

    ssh -i ${PRIVKEY} ${sshopts} ${user}@${ip} "sudo /bin/bash -x /tmp/fakeconfig.sh"
    retval=$?

    fc_reset_tasks
    return ${retval}
}

function setup_private_network() {
    # $1 - local network device
    # $2 - new bridge
    # $3 - hub device
    # $4... - cluster

    local localdev=$1
    local newbridge=$2
    local hubdev=$3

    shift; shift; shift

    hubdev_ip=$(ip_for_host ${hubdev})

    # set up all of the things on the hub
    fc_reset_tasks
    OPERANT_SERVER=${hubdev}

    echo "DOING HUB"
    for host in $@; do
        declare -a hostinfo
        hostinfo=(${host//:/ })
        host_name=${hostinfo[0]}
        host_ip=$(ip_for_host ${host_name})

        if [ "${host_name}" != ${hubdev} ]; then
            echo "Adding hub to ${host_name}"
            fc_add_task "gretap_to_host ${newbridge} ${localdev} ${host_ip} ${host_name}"
        fi
    done
    fc_do

    x_with_cluster "configuring private net ${localdev}" $@ <<EOF
        gretap_to_host ${newbridge} ${localdev} ${hubdev_ip} ${hubdev}
EOF
}

function template_file() {
    # $1 - template (assumed in SOURCE_DIR/templates)
    # $2 - destination

    local src=$1
    local dest=$2

    local full_src=${SOURCE_DIR}/templates/${src}

    if [ ! -e ${full_src} ]; then
        full_src=${src}
        if [ ! -e ${full_src} ]; then
            echo "Template file ${src} does not exist"
            return 1
        fi
    fi

    eval "echo \"$(< ${full_src})\"" > ${dest}
}

# grab log files from all the nodes in a cluster
# and drop them in subdirs under the node name
function cluster_fetch_file() {
    # $1 - remote path
    # $2 - local path (root of dir)
    # $3... - cluster nodes

    local remote_path="$1"
    local local_path="$2"
    shift; shift

    for host in $@; do
        mkdir -p ${local_path}/${host}
        background_task fetch_file ${host} "\"${remote_path}\"" ${local_path}/${host}
    done

    collect_tasks
}

# fetch a file from a node
function fetch_file() {
    # $1 - node (friendly name)
    # $2 - remote path (or remoted glob)
    # $3 - local path
    local friendly_name=$1
    local remote_path=$2
    local local_path=$3

    local ip=$(ip_for_host ${friendly_name})
    local sshopts="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
    local user=${LOGIN}

    scp -i ${PRIVKEY} ${sshopts} ${user}@${ip}:"${remote_path}" "${local_path}"
}

# we'll just lisp this up a bit - a cluster partial for you, wilk
function cluster_do {
    # $1 - cluster expressed as space separated string
    # $2 - thing to do that takes a server as first arg

    declare -a cluster=("${!1}")
    local thing=$2

    shift
    shift

    fc_reset_tasks

    for host in ${cluster[@]}; do
        background_task "${thing} ${host} $@"
    done

    collect_tasks
}

# This will be a add_task item for copying to remote
function template_to_remote() {
    echo "pass"
}
