#!/bin/bash -x

APPLICATION_ID=__APPLICATION_ID__
APPLICATION_PASSWORD=__APPLICATION_PASSWORD__
TENANT=__TENANT__
RESOURCE_GROUP=__RESOURCE_GROUP__

echo "`date` Resume invoked $0 $*" >> /var/log/slurmctld/power_save.log

if [ -z "$1" ]; then
    echo "No nodes specified, exiting." >> /var/log/slurmctld/power_save.log
    exit 0
fi

azure login -u "$APPLICATION_ID" -p "$APPLICATION_PASSWORD" --service-principal --tenant "$TENANT"
azure config mode arm

hosts=`scontrol show hostnames $1`
for host in $hosts
do
   echo "starting node $host" >> /var/log/slurmctld/power_save.log

   azure vm start --resource-group $RESOURCE_GROUP --name $host

   exitCode=$?

   echo "Command exited with $exitCode"
done

exit 0
