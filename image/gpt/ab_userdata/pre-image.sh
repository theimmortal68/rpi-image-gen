#!/bin/sh

set -eu

rootfs=$1
genimg_in=$2


# Load pre-defined UUIDs
. ${genimg_in}/img_uuids


# Set up the partition layout for tryboot support. Partition numbering
# relates directly to the layout in genimage.cfg.in

cat << EOF > "${genimg_in}/autoboot.txt"
[all]
tryboot_a_b=1
boot_partition=2
[tryboot]
boot_partition=3
EOF


# Write genimage template
cat genimage.cfg.in | sed \
   -e "s|<IMAGE_DIR>|$KSconf_sys_outputdir|g" \
   -e "s|<IMAGE_NAME>|$KSconf_image_name|g" \
   -e "s|<IMAGE_SUFFIX>|$KSconf_image_suffix|g" \
   -e "s|<FW_SIZE>|$KSconf_image_boot_part_size|g" \
   -e "s|<SYSTEM_SIZE>|$KSconf_image_system_part_size|g" \
   -e "s|<SECTOR_SIZE>|$KSconf_device_sector_size|g" \
   -e "s|<SLOTP>|'$(readlink -ef slot-post-process.sh)'|g" \
   -e "s|<MKE2FSCONF>|'$(readlink -ef mke2fs.conf)'|g" \
   -e "s|<BOOTA_LABEL>|$BOOTA_LABEL|g" \
   -e "s|<BOOTB_LABEL>|$BOOTB_LABEL|g" \
   -e "s|<SYSTEMA_UUID>|$SYSTEMA_UUID|g" \
   -e "s|<SYSTEMB_UUID>|$SYSTEMB_UUID|g" \
   > ${genimg_in}/genimage.cfg
