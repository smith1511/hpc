#!/bin/bash

set -x
#set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# != 7 ]; then
    echo "Usage: $0 <MasterHostname> <WorkerHostnamePrefix> <WorkerNodeCount> <HPCUserName> <TemplateBaseUrl> <ClusterFilesystem> <BeeGFSStoragePath>"
    exit 1
fi

# Set user args
MASTER_HOSTNAME=$1
WORKER_HOSTNAME_PREFIX=$2
WORKER_COUNT=$3
TEMPLATE_BASE_URL="$5"
CLUSTERFS="$6"
CLUSTERFS_STORAGE="$7"
LAST_WORKER_INDEX=$(($WORKER_COUNT - 1))

# Default to local disk
CLUSTERFS_STORAGE_PATH="/mnt/resource/storage"
if [ "$CLUSTERFS_STORAGE" == "Storage" ]; then
    CLUSTERFS_STORAGE_PATH="/data/beegfs/storage"
fi

# Shares
SHARE_ROOT=/share
SHARE_HOME=$SHARE_ROOT/home
SHARE_DATA=$SHARE_ROOT/data
SHARE_SCRATCH=$SHARE_ROOT/scratch
CLUSTERFS_METADATA_PATH=/data/beegfs/meta

# Munged
MUNGE_USER=munge
MUNGE_GROUP=munge
MUNGE_VERSION=0.5.11

# SLURM
SLURM_USER=slurm
SLURM_UID=6006
SLURM_GROUP=slurm
SLURM_GID=6006
SLURM_VERSION=15-08-1-1
SLURM_CONF_DIR=$SHARE_DATA/conf

# Hpc User
HPC_USER=$4
HPC_UID=7007
HPC_GROUP=hpc
HPC_GID=7007


# Returns 0 if this node is the master node.
#
is_master()
{
    hostname | grep "$MASTER_HOSTNAME"
    return $?
}


# Installs all required packages.
#
install_pkgs()
{
    if [ -d "/opt/intel/impi" ]; then
        # We're on the CentOS HPC image and need to freeze the kernel version
        sed -i 's/^exclude=kernel\*$/#exclude=kernel\*/g' /etc/yum.conf
    fi
    
    yum -y install epel-release
    yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl \
            openssl-devel openssl-libs gcc gcc-c++ nfs-utils rpcbind mdadm \
            wget python-pip kernel kernel-devel openmpi openmpi-devel automake \
            autoconf
}

# Partitions all data disks attached to the VM and creates
# a RAID-0 volume with them.
#
setup_data_disks()
{
    mountPoint="$1"
    filesystem="$2"
    createdPartitions=""

    # Loop through and partition disks until not found
    for disk in sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp sdq sdr; do
        fdisk -l /dev/$disk || break
        fdisk /dev/$disk << EOF
n
p
1


t
fd
w
EOF
        createdPartitions="$createdPartitions /dev/${disk}1"
    done

    # Create RAID-0 volume
    if [ -n "$createdPartitions" ]; then
        devices=`echo $createdPartitions | wc -w`
        mdadm --create /dev/md10 --level 0 --raid-devices $devices $createdPartitions
        if [ "$filesystem" == "xfs" ]; then
            mkfs -t $filesystem /dev/md10
            echo "/dev/md10 $mountPoint $filesystem rw,noatime,attr2,inode64,nobarrier,sunit=1024,swidth=4096,nofail 0 2" >> /etc/fstab
        else
            mkfs -t $filesystem /dev/md10
            echo "/dev/md10 $mountPoint $filesystem defaults,nofail 0 2" >> /etc/fstab
        fi
        mount /dev/md10
    fi
}

wait_for_master_nfs()
{
    while true; do
        showmount -e master | grep '^/share/home'
        if [ $? -eq 0 ]; then
            break;
        fi
        sleep 15
    done
}

wait_for_master_slurm_files()
{
    while true; do
        if [ -e "$SLURM_CONF_DIR/munge.key" ] && [ -e "$SLURM_CONF_DIR/slurm.conf" ]; then
            break
        fi
        sleep 15
    done
}

# Creates and exports two shares on the master nodes:
#
# /share/home (for HPC user)
# /share/data
#
# These shares are mounted on all worker nodes.
#
setup_shares()
{    
    if is_master; then
        if [ "$CLUSTERFS" == "BeeGFS" ]; then
            mkdir -p $CLUSTERFS_METADATA_PATH
            setup_data_disks $CLUSTERFS_METADATA_PATH "ext4"
            echo "$SHARE_HOME    *(rw,async)" >> /etc/exports
            echo "$SHARE_DATA    *(rw,async)" >> /etc/exports
        else
            mkdir -p $SHARE_ROOT
            setup_data_disks $SHARE_ROOT "ext4"
            echo "$SHARE_HOME    *(rw,async)" >> /etc/exports
            echo "$SHARE_DATA    *(rw,async)" >> /etc/exports
            echo "$SHARE_SCRATCH    *(rw,async)" >> /etc/exports
        fi
        
        mkdir -p $SHARE_HOME
        mkdir -p $SHARE_DATA
        mkdir -p $SHARE_SCRATCH
        
        systemctl enable rpcbind || echo "Already enabled"
        systemctl enable nfs-server || echo "Already enabled"
        systemctl start rpcbind || echo "Already enabled"
        systemctl start nfs-server || echo "Already enabled"
    else
        wait_for_master_nfs
        
        mkdir -p $SHARE_HOME
        mkdir -p $SHARE_DATA
        mkdir -p $SHARE_SCRATCH
            
        echo "master:$SHARE_HOME $SHARE_HOME    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        echo "master:$SHARE_DATA $SHARE_DATA    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        
        if [ "$CLUSTERFS" == "None" ]; then
            echo "master:$SHARE_SCRATCH $SHARE_SCRATCH    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        fi
        
        mkdir -p $CLUSTERFS_STORAGE_PATH
        setup_data_disks $CLUSTERFS_STORAGE_PATH "xfs"
        
        mount -a
        mount | grep "^master:$SHARE_HOME"
        mount | grep "^master:$SHARE_DATA"
        
        if [ "$CLUSTERFS" == "None" ]; then
            mount | grep "^master:$SHARE_SCRATCH"
        fi
    fi
}

# Downloads/builds/installs munged on the node.
# The munge key is generated on the master node and placed
# in the data share.
# Worker nodes copy the existing key from the data share.
#
install_munge()
{
    cwd=`pwd`
    mkdir -p $SHARE_DATA
    cd $SHARE_DATA
    
    mkdir -m 700 /etc/munge
    mkdir -m 711 /var/lib/munge
    mkdir -m 700 /var/log/munge
    mkdir -m 755 /var/run/munge
    
    groupadd $MUNGE_GROUP
    useradd -M -c "Munge service account" -g munge -s /usr/sbin/nologin munge
    
    chown -R munge:munge /etc/munge /var/lib/munge /var/log/munge /var/run/munge
    
    if is_master; then
        wget https://github.com/dun/munge/archive/munge-${MUNGE_VERSION}.tar.gz
        tar xvfz munge-$MUNGE_VERSION.tar.gz
        cd munge-munge-$MUNGE_VERSION
        ./configure -libdir=/usr/lib64 --prefix=/usr --sysconfdir=/etc --localstatedir=/var
        make
        make install
        
        dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
        mkdir -p $SLURM_CONF_DIR
        cp /etc/munge/munge.key $SLURM_CONF_DIR
    else
        wait_for_master_slurm_files
        make install
        cd munge-munge-$MUNGE_VERSION
        cp $SLURM_CONF_DIR/munge.key /etc/munge/munge.key
    fi

    chown munge:munge /etc/munge/munge.key
    chmod 0400 /etc/munge/munge.key

    /etc/init.d/munge start

    cd $cwd
}

# Installs and configures slurm.conf on the node.
# This is generated on the master node and placed in the data
# share.  All nodes create a sym link to the SLURM conf
# as all SLURM nodes must share a common config file.
#
install_slurm_config()
{
    if is_master; then

        mkdir -p $SLURM_CONF_DIR

        if [ -e "$TEMPLATE_BASE_URL/slurm.template.conf" ]; then
            cp "$TEMPLATE_BASE_URL/slurm.template.conf" .
        else
            wget "$TEMPLATE_BASE_URL/slurm.template.conf"
        fi

        cat slurm.template.conf |
        sed 's/__MASTER__/'"$MASTER_HOSTNAME"'/g' |
                sed 's/__WORKER_HOSTNAME_PREFIX__/'"$WORKER_HOSTNAME_PREFIX"'/g' |
                sed 's/__LAST_WORKER_INDEX__/'"$LAST_WORKER_INDEX"'/g' > $SLURM_CONF_DIR/slurm.conf
    fi

    ln -s $SLURM_CONF_DIR/slurm.conf /etc/slurm/slurm.conf
}

# Downloads, builds and installs SLURM on the node.
# Starts the SLURM control daemon on the master node and
# the agent on worker nodes.
#
install_slurm()
{
    cwd=`pwd`
    mkdir -p $SHARE_DATA
    cd $SHARE_DATA
    
    groupadd -g $SLURM_GID $SLURM_GROUP

    useradd -M -u $SLURM_UID -c "SLURM service account" -g $SLURM_GROUP -s /usr/sbin/nologin $SLURM_USER

    mkdir -p /etc/slurm /var/spool/slurmd /var/run/slurmd /var/run/slurmctld /var/log/slurmd /var/log/slurmctld

    chown -R slurm:slurm /var/spool/slurmd /var/run/slurmd /var/run/slurmctld /var/log/slurmd /var/log/slurmctld

    if is_master; then
        wget https://github.com/SchedMD/slurm/archive/slurm-$SLURM_VERSION.tar.gz
        tar xvfz slurm-$SLURM_VERSION.tar.gz
        cd slurm-slurm-$SLURM_VERSION
        ./configure -libdir=/usr/lib64 --prefix=/usr --sysconfdir=/etc/slurm && make && make install
    else
        cd slurm-slurm-$SLURM_VERSION
        make install
    fi

    install_slurm_config

    if is_master; then
        wget $TEMPLATE_BASE_URL/slurmctld.service
        mv slurmctld.service /usr/lib/systemd/system
        systemctl daemon-reload
        systemctl enable slurmctld
        systemctl start slurmctld
    else
        wget $TEMPLATE_BASE_URL/slurmd.service
        mv slurmd.service /usr/lib/systemd/system
        systemctl daemon-reload
        systemctl enable slurmd
        systemctl start slurmd
    fi

    cd $cwd
}

# Adds a common HPC user to the node and configures public key SSh auth.
# The HPC user has a shared home directory (NFS share on master) and access
# to the data share.
#
setup_hpc_user()
{
    # disable selinux
    sed -i 's/enforcing/disabled/g' /etc/selinux/config
    setenforce permissive
    
    groupadd -g $HPC_GID $HPC_GROUP

    # Don't require password for HPC user sudo
    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    
    # Disable tty requirement for sudo
    sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers

    if is_master; then
    
        useradd -c "HPC User" -g $HPC_GROUP -m -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER

        mkdir -p $SHARE_HOME/$HPC_USER/.ssh
        
        # Configure public key auth for the HPC user
        ssh-keygen -t rsa -f $SHARE_HOME/$HPC_USER/.ssh/id_rsa -q -P ""
        cat $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub > $SHARE_HOME/$HPC_USER/.ssh/authorized_keys

        echo "Host *" > $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    StrictHostKeyChecking no" >> $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    UserKnownHostsFile /dev/null" >> $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    PasswordAuthentication no" >> $SHARE_HOME/$HPC_USER/.ssh/config

        # Fix .ssh folder ownership
        chown -R $HPC_USER:$HPC_GROUP $SHARE_HOME/$HPC_USER

        # Fix permissions
        chmod 700 $SHARE_HOME/$HPC_USER/.ssh
        chmod 644 $SHARE_HOME/$HPC_USER/.ssh/config
        chmod 644 $SHARE_HOME/$HPC_USER/.ssh/authorized_keys
        chmod 600 $SHARE_HOME/$HPC_USER/.ssh/id_rsa
        chmod 644 $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub
        
        # Give hpc user access to data share
        chown $HPC_USER:$HPC_GROUP $SHARE_DATA
    else
        useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER
    fi
    
    chown $HPC_USER:$HPC_GROUP $SHARE_SCRATCH
}

# Sets all common environment variables and system parameters.
#
setup_env()
{
    # Set unlimited mem lock
    echo "$HPC_USER hard memlock unlimited" >> /etc/security/limits.conf
    echo "$HPC_USER soft memlock unlimited" >> /etc/security/limits.conf

    # Intel MPI config for IB
    echo "# IB Config for MPI" > /etc/profile.d/mpi.sh
    echo "export I_MPI_FABRICS=shm:dapl" >> /etc/profile.d/mpi.sh
    echo "export I_MPI_DAPL_PROVIDER=ofa-v2-ib0" >> /etc/profile.d/mpi.sh
    echo "export I_MPI_DYNAMIC_CONNECTION=0" >> /etc/profile.d/mpi.sh
}

install_easybuild()
{
    yum -y install Lmod python-devel python-pip gcc gcc-c++ patch unzip tcl tcl-devel libibverbs libibverbs-devel
    pip install vsc-base

    EASYBUILD_HOME=$SHARE_HOME/$HPC_USER/EasyBuild

    if is_master; then
        su - $HPC_USER -c "pip install --install-option --prefix=$EASYBUILD_HOME https://github.com/hpcugent/easybuild-framework/archive/easybuild-framework-v2.5.0.tar.gz"

        # Add Lmod to the HPC users path
        echo 'export PATH=/usr/lib64/openmpi/bin:/usr/share/lmod/6.0.15/libexec:$PATH' >> $SHARE_HOME/$HPC_USER/.bashrc

        # Setup Easybuild configuration and paths
        echo 'export PATH=$HOME/EasyBuild/bin:$PATH' >> $SHARE_HOME/$HPC_USER/.bashrc
        echo 'export PYTHONPATH=$HOME/EasyBuild/lib/python2.7/site-packages:$PYTHONPATH' >> $SHARE_HOME/$HPC_USER/.bashrc
        echo "export MODULEPATH=$EASYBUILD_HOME/modules/all" >> $SHARE_HOME/$HPC_USER/.bashrc
        echo "export EASYBUILD_MODULES_TOOL=Lmod" >> $SHARE_HOME/$HPC_USER/.bashrc
        echo "export EASYBUILD_INSTALLPATH=$EASYBUILD_HOME" >> $SHARE_HOME/$HPC_USER/.bashrc
        echo "export EASYBUILD_DEBUG=1" >> $SHARE_HOME/$HPC_USER/.bashrc
        echo "source /usr/share/lmod/6.0.15/init/bash" >> $SHARE_HOME/$HPC_USER/.bashrc
    fi
}

install_beegfs()
{    
    wget -O beegfs-rhel7.repo http://www.beegfs.com/release/latest-stable/dists/beegfs-rhel7.repo
    mv beegfs-rhel7.repo /etc/yum.repos.d/beegfs.repo
    rpm --import http://www.beegfs.com/release/latest-stable/gpg/RPM-GPG-KEY-beegfs
    
    yum install -y beegfs-client beegfs-helperd beegfs-utils
    
    sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MASTER_HOSTNAME'/g' /etc/beegfs/beegfs-client.conf
    sed -i  's/Type=oneshot.*/Type=oneshot\nRestart=always\nRestartSec=5/g' /etc/systemd/system/multi-user.target.wants/beegfs-client.service
    echo "$SHARE_SCRATCH /etc/beegfs/beegfs-client.conf" > /etc/beegfs/beegfs-mounts.conf
    
    if is_master; then
        yum install -y beegfs-mgmtd beegfs-meta
        mkdir -p /data/beegfs/mgmtd
        sed -i 's|^storeMgmtdDirectory.*|storeMgmtdDirectory = /data/beegfs/mgmt|g' /etc/beegfs/beegfs-mgmtd.conf
        sed -i 's|^storeMetaDirectory.*|storeMetaDirectory = '$CLUSTERFS_METADATA_PATH'|g' /etc/beegfs/beegfs-meta.conf
        sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MASTER_HOSTNAME'/g' /etc/beegfs/beegfs-meta.conf
        /etc/init.d/beegfs-mgmtd start
        /etc/init.d/beegfs-meta start
    else
        yum install -y beegfs-storage
        sed -i 's|^storeStorageDirectory.*|storeStorageDirectory = '$CLUSTERFS_STORAGE_PATH'|g' /etc/beegfs/beegfs-storage.conf
        sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MASTER_HOSTNAME'/g' /etc/beegfs/beegfs-storage.conf
        /etc/init.d/beegfs-storage start
    fi
    
    systemctl daemon-reload
}

install_xor()
{
    if is_master; then
        cd $SHARE_HOME/$HPC_USER
        mkdir IOR-2.10.3
	    cd IOR-2.10.3
	    wget http://www.nersc.gov/assets/Trinity--NERSC-8-RFP/Benchmarks/July12/IOR-July12.tar
	    tar xvf IOR-July12.tar
	    cd src/C
    	make mpiio
    	cd $SHARE_HOME/$HPC_USER
	    chown -R $HPC_USER:$HPC_GROUP IOR-2.10.3
	fi
}

setup_swap()
{
    sed -i 's|^ResourceDisk.EnableSwap=n|ResourceDisk.EnableSwap=y|g' /etc/waagent.conf
    sed -i 's|^ResourceDisk.SwapSizeMB=0|ResourceDisk.SwapSizeMB=4096' /etc/waagent.conf
}

setup_swap
install_pkgs
setup_shares
setup_hpc_user

if [ "$CLUSTERFS" == "BeeGFS" ]; then
    install_beegfs
fi

install_munge
install_slurm
setup_env
#install_easybuild
#install_xor

shutdown -r +1 &
exit 0
