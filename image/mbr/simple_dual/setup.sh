#!/bin/bash

set -eu

DISKLABEL=$1

case $DISKLABEL in
   ROOT)
      case $IGconf_image_rootfs_type in
         ext4)
            cat << EOF > $IMAGEMOUNTPATH/etc/fstab
/dev/disk/by-label/ROOT /               ext4 rw,relatime,errors=remount-ro 0 1
EOF
            ;;
         btrfs)
            cat << EOF > $IMAGEMOUNTPATH/etc/fstab
/dev/disk/by-label/ROOT /               btrfs defaults 0 1
EOF
            ;;
         *)
            ;;
      esac

      cat << EOF >> $IMAGEMOUNTPATH/etc/fstab
/dev/disk/by-label/BOOT /boot/firmware  vfat rw,noatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,errors=remount-ro 0 2
EOF
      image2json -g $OUTPUTPATH/genimage.cfg -f $IMAGEMOUNTPATH/etc/fstab > $OUTPUTPATH/image.json
      ;;
   BOOT)
      sed -i "s|root=\([^ ]*\)|root=\/dev\/disk\/by-label\/ROOT|" $IMAGEMOUNTPATH/cmdline.txt
      ;;
   *)
      ;;
esac
