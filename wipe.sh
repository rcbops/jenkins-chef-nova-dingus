#!/bin/bash
# stupid cleanup script

. nova-credentials

if [ "$1" = "" ]; then
    chef=$(nova list | grep chef-server | awk '{ print $4 }' | head -n1)
    job=${chef%%-*}
else
    job=$1
fi

echo "Job: ${job}"

for d in $(nova list | grep ${job} | awk '{ print $4 }' ); do
    echo "Deleting ${d}"
    nova delete ${d}
done
