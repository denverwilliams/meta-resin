#!/bin/bash

echo 1 > /sys/class/leds/beaglebone:green:heartbeat/brightness
# Copy the config over to tmp to start provisioning
strings -n 1 /dev/mmcblk0p3 > /tmp/config.json

# set API_ENDPOINT and CONFIG_PATH
# file generated by supervisor-init(-dev) recipe
source /etc/resin.conf
export CONFIG_PATH=/tmp/config.json #Redefine the config path used for provisioning.
export API_ENDPOINT CONFIG_PATH
uuid=$(openssl rand -hex 31)
config_json=`cat $CONFIG_PATH`
echo $config_json | jq ".uuid=\"$uuid\"" > $CONFIG_PATH
resin-device-register &

resin-device-progress 0 "Partitioning eMMC" || true

# Card config
export SDCARD=/dev/mmcblk1
# Boot partition size [in KiB]
export BOOT_SIZE=20480 # 20 MB
# Rootfs Size [in KiB]
export ROOTFS_SIZE=122880 # 120 MB

# First partition begin at sector 8192 - Leaving - 4MB of space
export IMAGE_ROOTFS_ALIGNMENT=4096

# Align partitions
export BOOT_SIZE_ALIGNED=$(expr ${BOOT_SIZE} + ${IMAGE_ROOTFS_ALIGNMENT} - 1)
export BOOT_SIZE_ALIGNED=$(expr ${BOOT_SIZE_ALIGNED} - ${BOOT_SIZE_ALIGNED} % ${IMAGE_ROOTFS_ALIGNMENT})

# Create Partition table
parted -s ${SDCARD} mklabel msdos

# Create boot partition and mark it as bootable
parted -s ${SDCARD} unit KiB mkpart primary fat16 ${IMAGE_ROOTFS_ALIGNMENT} $(expr ${BOOT_SIZE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT})
parted -s ${SDCARD} set 1 boot on
        
# Create A rootfs partition
parted -s ${SDCARD} unit KiB mkpart primary ext4 $(expr ${BOOT_SIZE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT}) $(expr ${BOOT_SIZE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT} \+ ${ROOTFS_SIZE})

# Create B rootfs partition
parted -s ${SDCARD} unit KiB mkpart primary ext4 $(expr ${BOOT_SIZE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT} \+ ${ROOTFS_SIZE}) $(expr ${BOOT_SIZE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT} \+ ${ROOTFS_SIZE} \+ ${ROOTFS_SIZE})

# Create docker data partition with the rest of the space.
parted -s ${SDCARD} unit KiB mkpart primary ext4 $(expr ${BOOT_SIZE_ALIGNED} \+ ${IMAGE_ROOTFS_ALIGNMENT} \+ ${ROOTFS_SIZE} \+ ${ROOTFS_SIZE}) 100%

parted ${SDCARD} print

partprobe

mkfs.vfat -F 16 /dev/mmcblk1p1  #BOOT
mkfs.ext4 /dev/mmcblk1p2  #ROOT
mkfs.btrfs -f /dev/mmcblk1p4 #DATA

resin-device-progress 20 "Copying System files to eMMC" || true

echo 1 > /sys/class/leds/beaglebone:green:mmc0/brightness

mkdir -p /tmp/new_root
mkdir -p /tmp/new_boot
mkdir -p /tmp/boot

mount /dev/mmcblk0p1 /tmp/boot # This is not mounted at /boot by default.
mount /dev/mmcblk1p2 /tmp/new_root
mount /dev/mmcblk1p1 /tmp/new_boot

cp /tmp/boot/MLO /tmp/new_boot/ # This needs to go first into the partition.
cp /tmp/boot/u-boot-emmc.img /tmp/new_boot/u-boot.img # Copy the emmc specific u-boot to emmc
cp /tmp/boot/VERSION /tmp/new_boot/VERSION # Copy the build info
rsync -a -W --no-compress --numeric-ids --exclude='/tmp/*' --exclude='/dev/*' --exclude='/resin-data/*' --exclude='/srv/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/var/volatile/*' --exclude='/run/*' / /tmp/new_root/ # rsync the rest of the files.

resin-device-progress 30 "Writing System configuration." || true

export BOOTUUID=`blkid -s UUID -o value /dev/mmcblk1p1`
export ROOTPARTUUID=`blkid -s PARTUUID -o value /dev/mmcblk1p2`
export BTRFSUUID=`blkid -s UUID -o value /dev/mmcblk1p4`

echo "uenvcmd=setenv mmcroot PARTUUID=${ROOTPARTUUID} ro;" > /tmp/new_boot/uEnv.txt
echo 1 > /tmp/new_boot/REMOVE_TO_REPROVISION_${BOOTUUID}
echo 1 > /tmp/boot/REMOVE_TO_REPROVISION_${BOOTUUID}
# The following command ensures reboot to the new env immediately after provisioning and at the same time it ensures that the same SD card can be used to provision multiple Beagblebones in one shot.
echo "uenvcmd=if load mmc 0 0x82000000 REMOVE_TO_REPROVISION_${BOOTUUID}; then if load mmc 1 0x82000000 REMOVE_TO_REPROVISION_${BOOTUUID};then setenv mmcdev 1; run mmcboot; fi; fi;" > /tmp/boot/uEnv.txt
# Add the mount points for proper mounting on boot
echo "UUID=${BTRFSUUID}         /mnt/data-disk  btrfs   defaults        0       0" >> /tmp/new_root/etc/fstab


echo 1 > /sys/class/leds/beaglebone:green:usr2/brightness
resin-device-progress 50 "Loading Resin Supervisor." || true
# Load the supervisor container
mount /dev/mmcblk1p4 /mnt/data-disk
cp /tmp/config.json /mnt/data-disk/config.json # Copy the provisioned json to the new_root
ln -sf /mnt/data-disk/config.json /tmp/new_root/boot/config.json

mkdir -p /mnt/data-disk/docker /mnt/data-disk/resin-data
mount -o bind /mnt/data-disk/docker /var/lib/docker
# docker 1.4.1 Needs a .docker directory in / :|
mkdir -p /tmp/.docker
mount -o bind /tmp/.docker /.docker
docker -d -s btrfs &
# Wait for docker to become ready
echo "Waiting for docker to become ready.."
while [ ! -S /var/run/docker.sock ]
do
	sleep 1
done
docker load < /resin-data/armhfv7-supervisor.tar && sync && killall docker && sync
sync && sync && umount /dev/mmcblk1p1 && umount /dev/mmcblk1p2 && umount /var/lib/docker && umount /dev/mmcblk1p4 && umount /dev/mmcblk0p1

echo 1 > /sys/class/leds/beaglebone:green:usr3/brightness
resin-device-progress 90 "Rebooting to the newly installed eMMC" || true
echo "Rebooting"

reboot -f
