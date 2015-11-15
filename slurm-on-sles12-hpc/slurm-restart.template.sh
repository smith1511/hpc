#!/bin/bash

MASTER_NAME=__MASTER__
WORKER_HOSTNAME_PREFIX=__WORKER_HOSTNAME_PREFIX__

pkill -SIGHUP slurmctld

if [ $? -ne 0 ]; then
    echo "Error restarting slurmctld"
fi

nodeIndex=0

while [ 0 ]; do

    node=${WORKER_HOSTNAME_PREFIX}$nodeIndex
	
    nslookup $node > /dev/null
    if [ $? -ne 0 ]; then
        break
    fi

    echo "Restarting slurmd on $node..."
	
    # restart worker
	sudo -u hpc ssh $node "sudo pkill -SIGHUP slurmd" &
	
	nodeIndex=$(($nodeIndex + 1))
	
done
