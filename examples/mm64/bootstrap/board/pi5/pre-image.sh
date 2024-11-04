#!/bin/sh

board_top=$(readlink -f $(dirname "$0"))
rootfs=$1
genimg_in=$2

# Install config.txt with defaults more aligned with pi5
cp ${board_top}/config.txt ${rootfs}/boot/firmware/config.txt
