#!/bin/sh

set -eu

rootfs=$1
genimg_in=$2

# Generate the config for genimage to ingest:
# FIXME - sizes should be easily configurable
FW_SIZE=200%
ROOT_SIZE=300%

SETUP=$(readlink -f setup.sh)

cat genimage.cfg.in | sed \
   -e "s|<IMAGE_DIR>|$IGconf_image_outputdir|g" \
   -e "s|<IMAGE_NAME>|$IGconf_image_name|g" \
   -e "s|<IMAGE_SUFFIX>|$IGconf_image_suffix|g" \
   -e "s|<FW_SIZE>|$FW_SIZE|g" \
   -e "s|<ROOT_SIZE>|$ROOT_SIZE|g" \
   -e "s|<SETUP>|'$SETUP'|g" \
   > ${genimg_in}/genimage.cfg
