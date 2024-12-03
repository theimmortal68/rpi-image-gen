#!/bin/bash

set -u

# Copy the firmware image set into the target fs so it'll be available.
mkdir ${IMAGEMOUNTPATH}/fw-store
rsync -av ${OUTPUTPATH}/firmware.squashfs ${IMAGEMOUNTPATH}/fw-store

# It will be mounted on the target here
mkdir -p ${IMAGEMOUNTPATH}/mnt/firmware
