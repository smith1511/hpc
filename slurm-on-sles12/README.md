# Deploy a slurm cluster

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsmith1511%2Fhpc%2Fmaster%2Fslurm-on-sles12%2Fazuredeploy.json" target="_blank">
   <img alt="Deploy to Azure" src="http://azuredeploy.net/deploybutton.png"/>
</a>

1. Fill in the 3 mandatory parameters - public DNS name, a storage account to hold VM image, and admin user password.

2. Select an existing resource group or enter the name of a new resource group to create.

3. Select the resource group location.

4. Accept the terms and agreements/

5. Click Create.

## Using the cluster

Simply SSH to the master node and do a srun! The DNS name is _**dnsName**_._**location**_.cloudapp.azure.com, for example, slurm12-hpc.westus.cloudapp.azure.com.

You can log into the cluster user the admin user and password specified.  Once on the head node you can switch to the HPC user.  For security reasons this user cannot login to the head node directly.

The HPC user can SSH to all nodes using public key authentication.  The HPC users home directory is a NFS share on the master and shared by all nodes for this user.

The master node has a 16 disk RAID-0 under /share/data.  This is available at the same location on all worker nodes.
