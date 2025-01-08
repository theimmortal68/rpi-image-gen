#!/bin/bash

set -eu

DISKLABEL=$1

case $DISKLABEL in
   ROOT)
      cat << EOF > $IMAGEMOUNTPATH/etc/fstab
/dev/disk/by-label/ROOT /               ext4 rw,relatime,errors=remount-ro 0 1
/dev/disk/by-label/BOOT /boot/firmware  vfat rw,noatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,errors=remount-ro 0 2
EOF
      ;;
   BOOT)
      sed -i "s|root=\([^ ]*\)|root=\/dev\/disk\/by-label\/ROOT|" $IMAGEMOUNTPATH/cmdline.txt
      ;;
   *)
      ;;
esac
