# BeeGFS on CentOS 7.2 ARM Template with Metadata service on Storage nodes

Deploys a BeeGFS cluster with metadata and storage nodes.

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsmith1511%2Fhpc%2Fmaster%2Fbeegfs-shared-on-centos7.2%2Fazuredeploy.json" target="_blank">
   <img alt="Deploy to Azure" src="http://azuredeploy.net/deploybutton.png"/>
</a>

1. Fill in the mandatory parameters.

2. Select an existing resource group or enter the name of a new resource group to create.

3. Select the resource group location.

4. Accept the terms and agreements.

5. Click Create.

## Accessing the cluster

Simply SSH to the master node using the IP address.

```
# ssh azureuser@123.123.123.123
```

You can log into the first metadata node using the admin user and password specified.
