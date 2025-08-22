#!/bin/bash

set -u

if igconf isset image_pmap ; then
   [[ -d "${KS_IMAGE}/device" ]] || die "No device directory for pmap $KSconf_image_pmap"
   [[ -f "${KS_IMAGE}/device/provisionmap-${KSconf_image_pmap}.json" ]] || die "pmap not found"
fi
