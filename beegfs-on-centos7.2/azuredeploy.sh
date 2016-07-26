#!/bin/bash

set -x
#set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# != 5 ]; then
    echo "Usage: $0 <MetadataNodePrefix> <MetadataNodeCount> <StorageNodePrefix> <StorageNodeCount> <TemplateBaseUrl>"
    exit 1
fi

# Set user args
METADATA_HOSTNAME_PREFIX=$1
METADATA_COUNT=$2
STORAGE_HOSTNAME_PREFIX=$3
STORAGE_COUNT=$4
TEMPLATE_BASE_URL="$5"
# Use the first metadata server for management server
MGMT_HOSTNAME=${METADATA_HOSTNAME_PREFIX}0

# Shares
SHARE_SCRATCH=/share/scratch
BEEGFS_METADATA=/data/beegfs/meta
BEEGFS_STORAGE=/data/beegfs/storage

is_mgmtnode()
{
    hostname | grep "${METADATA_HOSTNAME_PREFIX}0"
    return $?
}

is_metadatanode()
{
    hostname | grep "$METADATA_HOSTNAME_PREFIX"
    return $?
}

is_storagenode()
{
    hostname | grep "$STORAGE_HOSTNAME_PREFIX"
    return $?
}


# Installs all required packages.
#
install_pkgs()
{
    yum -y install epel-release
    yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs gcc gcc-c++ nfs-utils rpcbind mdadm wget python-pip kernel kernel-devel openmpi openmpi-devel automake autoconf
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
            mkfs.ext4 -i 2048 -I 512 -J size=400 -Odir_index,filetype /dev/md10
            sleep 5
            tune2fs -o user_xattr /dev/md10
            echo "/dev/md10 $mountPoint $filesystem noatime,nodiratime,nobarrier,nofail 0 2" >> /etc/fstab
        fi
        mount /dev/md10
    fi
}

setup_disks()
{
    mkdir -p $SHARE_SCRATCH

    if is_metadatanode; then
        mkdir -p $BEEGFS_METADATA
        setup_data_disks $BEEGFS_METADATA "ext4"
    fi

    if is_storagenode; then
        mkdir -p $BEEGFS_STORAGE
        setup_data_disks $BEEGFS_STORAGE "xfs"
        mount -a
    fi
}

install_beegfs()
{
    # Install BeeGFS repo
    wget -O beegfs-rhel7.repo http://www.beegfs.com/release/latest-stable/dists/beegfs-rhel7.repo
    mv beegfs-rhel7.repo /etc/yum.repos.d/beegfs.repo
    rpm --import http://www.beegfs.com/release/latest-stable/gpg/RPM-GPG-KEY-beegfs

    if is_mgmtnode; then
        yum install -y beegfs-mgmtd beegfs-client beegfs-helperd beegfs-utils
        
        # Install management server and client
        mkdir -p /data/beegfs/mgmtd
        sed -i 's|^storeMgmtdDirectory.*|storeMgmtdDirectory = /data/beegfs/mgmt|g' /etc/beegfs/beegfs-mgmtd.conf
        systemctl daemon-reload
        systemctl enable beegfs-mgmtd.service
        systemctl start beegfs-mgmtd.service
        
        # setup client
        sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-client.conf
        sed -i  's/Type=oneshot.*/Type=oneshot\nRestart=always\nRestartSec=5/g' /etc/systemd/system/multi-user.target.wants/beegfs-client.service
        echo "$SHARE_SCRATCH /etc/beegfs/beegfs-client.conf" > /etc/beegfs/beegfs-mounts.conf
        systemctl daemon-reload
        systemctl enable beegfs-helperd.service
        systemctl enable beegfs-client.service
    fi
    
    if is_metadatanode; then
        yum install -y beegfs-meta
        sed -i 's|^storeMetaDirectory.*|storeMetaDirectory = '$BEEGFS_METADATA'|g' /etc/beegfs/beegfs-meta.conf
        sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-meta.conf
        systemctl daemon-reload
        systemctl enable beegfs-meta.service
        systemctl start beegfs-meta.service
        
        echo deadline > /sys/block/sdX/queue/scheduler
    fi
    
    if is_storagenode; then
        yum install -y beegfs-storage
        sed -i 's|^storeStorageDirectory.*|storeStorageDirectory = '$BEEGFS_STORAGE'|g' /etc/beegfs/beegfs-storage.conf
        sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-storage.conf
        systemctl daemon-reload
        systemctl enable beegfs-storage.service
        systemctl start beegfs-storage.service
    fi
}

setup_swap()
{
    fallocate -l 5g /mnt/resource/swap
	chmod 600 /mnt/resource/swap
	mkswap /mnt/resource/swap
	swapon /mnt/resource/swap
	echo "/mnt/resource/swap   none  swap  sw  0 0" >> /etc/fstab
}

setup_swap
install_pkgs
setup_disks
install_beegfs
shutdown -r +1 &
exit 0
