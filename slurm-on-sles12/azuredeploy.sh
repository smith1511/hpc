#!/bin/bash

set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# != 5 ]; then
    echo "Usage: $0 <MasterHostname> <WorkerHostnamePrefix> <WorkerNodeCount> <HPCUserName> <TemplateBaseUrl>"
    exit 1
fi

# Set user args
MASTER_HOSTNAME=$1
WORKER_HOSTNAME_PREFIX=$2
WORKER_COUNT=$3
HPC_USER=$4
TEMPLATE_BASE_URL="$5"
LAST_WORKER_INDEX=$(($WORKER_COUNT - 1))

WORKING_DIR="`pwd`"
MUNGE_USER=munge
MUNGE_GROUP=munge
SLURM_USER=slurm
SLURM_UID=6006
SLURM_GROUP=slurm
SLURM_GID=6006
SLURM_VERSION=15-08-1-1
HPC_UID=7007
HPC_GROUP=users
SHARE_HOME=/share/home
SHARE_DATA=/share/data


is_master()
{
    hostname | grep "$MASTER_HOSTNAME"
    return $?
}

add_sdk_repo()
{
    echo "Installing SLES 12 SDK Repository"

    repoFile="/etc/zypp/repos.d/SMT-http_smt-azure_susecloud_net:SLE-SDK12-Pool.repo"
    if [ -e "$repoFile" ]; then
        echo "SLES 12 SDK Repository already installed"
        return 0
    fi
	
	wget $TEMPLATE_BASE_URL/sles12sdk.repo
	
	cp sles12sdk.repo "$repoFile"

    # init repo
    zypper -n search nfs > /dev/null 2>&1
}

install_pkgs()
{
    pkgs="libbz2-1 libz1 openssl libopenssl-devel gcc gcc-c++ nfs-client rpcbind"

    if is_master; then
        pkgs="$pkgs nfs-kernel-server"
    fi

    zypper -n install $pkgs
}


setup_shares()
{

    mkdir -p $SHARE_HOME
    mkdir -p $SHARE_DATA

    if is_master; then
        echo "$SHARE_HOME    *(rw,async)" >> /etc/exports
        echo "$SHARE_DATA    *(rw,async)" >> /etc/exports
        service nfsserver status && service nfsserver reload || service nfsserver start
    else
        echo "master:$SHARE_HOME $SHARE_HOME    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        echo "master:$SHARE_DATA $SHARE_DATA    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        mount -a
        mount | grep "^master:$SHARE_HOME"
        mount | grep "^master:$SHARE_DATA"
    fi
}


install_munge()
{
    echo "Installing munge"

    groupadd $MUNGE_GROUP

    useradd -M -c "Munge service account" -g munge -s /usr/sbin/nologin munge

    mkdir munge
    cd munge

    wget https://github.com/dun/munge/archive/munge-0.5.11.tar.gz

    tar xvfz munge-0.5.11.tar.gz

    cd munge-munge-0.5.11*

    mkdir -m 700 /etc/munge
    mkdir -m 711 /var/lib/munge
    mkdir -m 700 /var/log/munge
    mkdir -m 755 /var/run/munge

    ./configure -libdir=/usr/lib64 --prefix=/usr --sysconfdir=/etc --localstatedir=/var

    make

    make install

    chown -R munge:munge /etc/munge /var/lib/munge /var/log/munge /var/run/munge

    if is_master; then
        dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
        cp /etc/munge/munge.key $SHARE_DATA
    else
        cp $SHARE_DATA/munge.key /etc/munge/munge.key
    fi

    chown munge:munge /etc/munge/munge.key
    chmod 0400 /etc/munge/munge.key

    /etc/init.d/munge start

    cd $WORKING_DIR
}


install_slurm_config()
{

    if is_master; then
	
	    wget "$TEMPLATE_BASE_URL/slurm.template.conf"
		
		cat slurm.template.conf |
		        sed 's/__MASTER__/'"$MASTER_HOSTNAME"'/g' |
				sed 's/__WORKER_HOSTNAME_PREFIX__/'"$WORKER_HOSTNAME_PREFIX"'/g' |
				sed 's/__LAST_WORKER_INDEX__/'"$LAST_WORKER_INDEX"'/g' > slurm.conf

        mkdir -p $SHARE_DATA/slurm
        mv slurm.conf $SHARE_DATA/slurm/
    fi

    ln -s $SHARE_DATA/slurm/slurm.conf /etc/slurm/
}


install_slurm()
{
    mkdir slurm
    cd slurm

    groupadd -g $SLURM_GID $SLURM_GROUP

    useradd -M -u $SLURM_UID -c "SLURM service account" -g $SLURM_GROUP -s /usr/sbin/nologin $SLURM_USER

    mkdir /etc/slurm /var/spool/slurmd /var/run/slurmd /var/run/slurmctld /var/log/slurmd /var/log/slurmctld

    chown -R slurm:slurm /var/spool/slurmd /var/run/slurmd /var/run/slurmctld /var/log/slurmd /var/log/slurmctld

    wget https://github.com/SchedMD/slurm/archive/slurm-$SLURM_VERSION.tar.gz

    tar xvfz slurm-$SLURM_VERSION.tar.gz

    cd slurm-slurm-$SLURM_VERSION
    ./configure -libdir=/usr/lib64 --prefix=/usr --sysconfdir=/etc/slurm && make
    make
    make install

    install_slurm_config

    if is_master; then
        /usr/sbin/slurmctld -vvvv
    else
        /usr/sbin/slurmd -vvvv
    fi

    cd $WORKING_DIR
}

setup_hpc_user()
{
    if is_master; then
        useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -m -u $HPC_UID $HPC_USER
        sudo -u $HPC_USER ssh-keygen -t rsa -f $SHARE_HOME/$HPC_USER/.ssh/id_rsa -q -P ""

        cat $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub > $SHARE_HOME/$HPC_USER/.ssh/authorized_keys
        echo "Host *" > $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    StrictHostKeyChecking no" >> $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    UserKnownHostsFile /dev/null" >> $SHARE_HOME/$HPC_USER/.ssh/config
		echo "    PasswordAuthentication no" >> $SHARE_HOME/$HPC_USER/.ssh/config

        chown $HPC_USER:$HPC_GROUP $SHARE_HOME/$HPC_USER/.ssh/authorized_keys
        chown $HPC_USER:$HPC_GROUP $SHARE_HOME/$HPC_USER/.ssh/config
    else
        useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER
    fi

    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
}

add_sdk_repo
install_pkgs
setup_shares
setup_hpc_user
install_munge
install_slurm
