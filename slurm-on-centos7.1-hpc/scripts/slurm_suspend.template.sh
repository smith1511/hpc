#!/bin/bash -x

APPLICATION_ID=__APPLICATION_ID__
APPLICATION_PASSWORD='__APPLICATION_PASSWORD__'
TENANT=__TENANT_ID__
RESOURCE_GROUP=__RESOURCE_GROUP__
LOG_FILE=/var/log/slurmctld/power_save.log

echo "`date` Suspend invoked $0 $*" >> $LOG_FILE

if [ -z "$1" ]; then
    echo "No nodes specified, exiting." >> $LOG_FILE
    exit 0
fi

azure login -u "$APPLICATION_ID" -p "$APPLICATION_PASSWORD" --service-principal --tenant "$TENANT" >> $LOG_FILE
azure config mode arm >> $LOG_FILE

hosts=`scontrol show hostnames $1`
for host in $hosts
do
   echo "Deallocating node $host" >> $LOG_FILE
   azure vm deallocate --resource-group $RESOURCE_GROUP --name $host >> $LOG_FILE &
done

failures=0

for job in `jobs -p`
do
echo $job
    wait $job || let "failures+=1"
done

if [ $failures -gt 0 ]; then
    echo "Failures occurred stopping VMs: $failures"
    exit 1
fi

exit 0
