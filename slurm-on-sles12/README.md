# Azure SLES 12 HPC ARM Template

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsmith1511%2Fhpc%2Fmaster%2Fslurm-on-sles12%2Fazuredeploy.json" target="_blank">
   <img alt="Deploy to Azure" src="http://azuredeploy.net/deploybutton.png"/>
</a>

1. Fill in the 3 mandatory parameters - public DNS name, a storage account to hold VM image, and admin user password.

2. Select an existing resource group or enter the name of a new resource group to create.

3. Select the resource group location.

4. Accept the terms and agreements.

5. Click Create.

## Accessing the cluster

Simply SSH to the master node and do a srun! The DNS name is _**dnsName**_._**location**_.cloudapp.azure.com, for example, slurm12-hpc.westus.cloudapp.azure.com.

You can log into the cluster user the admin user and password specified.  Once on the head node you can switch to the HPC user.  For security reasons this user cannot login to the head node directly.

## Running workloads

### HPC User

After SSHing to the head node you can switch to the HPC user specified on creation, the default username is 'hpc'.  This is a special user that should be used to run work and/or SLURM jobs.  The HPC user can SSH to all nodes using public key authentication.  The HPC users home directory is a NFS share on the master and shared by all nodes for this user.

To switch to the HPC user:

```
# su hpc
```

### Shares

The HPC user home directory is located in /share/home and is shared by all nodes across the cluster.

The master node exports a 16 disk RAID-0 share under /share/data.  This share is mounted under the same locations on all worker nodes.  Because this volume consists of 16 individual disks you can expect much better IO from it and it should be used for any share data across the cluster.

### Running a SLURM job

To verify that SLURM is configured and running as expected you can execute the following.

```
hpc# srun -N<Nodes> hostname
```

Replace <Nodes> with the number of worker nodes your cluster was configured with.  The output of the command should print out the hostname of each node.
