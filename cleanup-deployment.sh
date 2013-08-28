#!/bin/bash -e

# Script to safely delete nova instances and quantum networks from 
# the jenkins build cluster.
#
#   written by invsblduck <brett.campbell@rackspace.com>

function usage
{
    cat <<EOH
usage: ${0##*/} <name_regex> [<status>]

where <name_regex> is a regex to match instance or network names, and
<status> is the nova instance status to match ("ACTIVE" by default).

EOH
    exit 1
}

# don't need getopt yet
[ -z $1 ] && usage
[[ "$1" =~ ^--?h(elp)?$ ]] && usage
    
REGEX=$1
STATUS=${2:-ACTIVE}

function cleanup
{
    rm -f $tmp_instances
    rm -f $tmp_networks
    rm -f $tmp_subnets
}
trap cleanup EXIT

tmp_instances=`mktemp`
tmp_networks=`mktemp`
tmp_subnets=`mktemp`

echo "[*] Finding matching instances and/or networks..."
nova list --name "$REGEX" --status $STATUS >$tmp_instances
quantum net-list  >$tmp_networks    # can't --name here, have to grep these
quantum subnet-list  >$tmp_subnets  #

# when no instances are found, the output file size is 1 byte ('\n').
# but check for empty file too.
if [ $(stat $tmp_instances |grep -w Size |awk '{print $2}') = 1 \
    -o ! -s $tmp_instances ]
then
    echo
    echo -e "[-] ==> \e[1;41;33mNo instances match /$REGEX/\e[0m"
    if grep -Eq "$REGEX" $tmp_networks $tmp_subnets; then
        echo
        echo "[*] But the following networks match:"
        for f in $tmp_networks $tmp_subnets; do
            head -3 $f
            grep -Eh --color=always "$REGEX" $f
            tail -1 $f
            echo
        done
        read -p "[*] Delete these networks? [y/N]: "
        if [ -z "$REPLY" ] || [[ ! "$REPLY" =~ ^[yY] ]]; then
            echo "[-] exiting."
            exit 2
        fi
    else
        echo "[-] ==> (No networks match either)"
        echo 
        exit
    fi
else
    # make sure we didn't grab too many instances
    if [ $(grep -E "$REGEX" $tmp_instances |wc -l) -gt 5 ]
    then
        echo
        echo "[*] Regex /$REGEX/ matches > 5 instances:"
        cat $tmp_instances
        echo
        read -p "[*] Really delete instances? [y/N]: "
        if [ -z "$REPLY" ] || [[ ! "$REPLY" =~ ^[yY] ]]; then
            echo "[-] exiting."
            exit 2
        fi
    fi

    err=
    IFS_SAVE=$IFS
    IFS=$'\n'
    for line in $(grep -E "$REGEX" $tmp_instances); do
        id=$(echo $line |awk '{print $2}')
        name=$(echo $line |awk '{print $4}')
        if [ -z "$id" -o -z "$name" ]; then
            echo "[?] skipping bad data:"
            echo "[?] $line"
            continue
        fi
        echo "[+] Deleting instance $name ($id)"
        set +e; nova delete $id || err=true; set -e
    done
    IFS=$IFS_SAVE
    
    if [ -n "$err" ]; then
        echo
        echo "[-] Some instances failed to delete :("
        echo "[-] ==> Not deleting quantum networks!"
        echo "[-] ==> exiting."
        exit 1
    fi

    # wait for instances to terminate
    echo
    echo "[*] Waiting for instances to fully terminate..."
    for ((i=0; i<12; i++)); do
        # XXX maybe need to check for 'deleting' status or such?
        nova list --name "$REGEX" --status $STATUS |grep -Eq "$REGEX" || break
        sleep 5
    done

    # did we timeout?
    if [ $i = 12 ]; then
        echo "[-] ==> Timed out!"
        echo "[-] ==> exiting."
        exit 1
    fi
    echo "[*] ok"
    echo
fi

# delete networks
# FIXME need generic functions for copy/pasted/tweaked code
#
if grep -Eq "$REGEX" $tmp_networks $tmp_subnets
then
    # make sure we don't delete too many networks by accident
    if [ $(grep -E "$REGEX" $tmp_networks $tmp_subnets |wc -l) -gt 4 ]
    then
        echo
        echo "[*] Regex /$REGEX/ matches > 4 networks:"
        for f in $tmp_networks $tmp_subnets; do
            head -3 $f
            grep -Eh --color=always "$REGEX" $f
            tail -1 $f
            echo
        done
        read -p "[*] Really delete networks? [y/N]: "
        if [ -z "$REPLY" ] || [[ ! "$REPLY" =~ ^[yY] ]]; then
            echo "[-] exiting."
            exit 2
        fi
    fi

    err=
    IFS_SAVE=$IFS
    IFS=$'\n'
    for line in $(grep -E "$REGEX" $tmp_subnets); do
        id=$(echo $line |awk '{print $2}')
        name=$(echo $line |awk '{print $4}')
        if [ -z "$id" -o -z "$name" ]; then
            echo "[?] skipping bad data:"
            echo "[?] $line"
            continue
        fi
        echo "[+] Deleting subnet $name ($id)"
        set +e; quantum subnet-delete $id >/dev/null || err=true; set -e
    done
    IFS=$IFS_SAVE

    if [ -n "$err" ]; then
        echo
        echo "[-] Failed to delete one or more subnets :("
        echo "[-] ==> Not deleting quantum networks!"
        echo "[-] ==> exiting."
        exit 1
    fi

    err=
    IFS_SAVE=$IFS
    IFS=$'\n'
    for line in $(grep -E "$REGEX" $tmp_networks); do
        id=$(echo $line |awk '{print $2}')
        name=$(echo $line |awk '{print $4}')
        if [ -z "$id" -o -z "$name" ]; then
            echo "[?] skipping bad data:"
            echo "[?] $line"
            continue
        fi
        echo "[+] Deleting network $name ($id)"
        set +e; quantum net-delete $id >/dev/null || err=true; set -e
    done
    IFS=$IFS_SAVE

    if [ -n "$err" ]; then
        echo
        echo "[-] Failed to delete one or more networks :("
        echo "[-] exiting."
        exit 1
    fi
fi

echo
echo "[*] clean ;)"
echo
