#!/bin/bash
# shellcheck disable=SC2154

set -eu

rootfs=$1
outdir=$2

SYFT_VER=v1.27.1

# If host has syft, use it
if ! hash syft 2>/dev/null; then
   curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
      | sh -s -- -b "${KSconf_sys_workdir}"/host/bin "${SYFT_VER}"
fi

SYFT=$(syft --version 2>/dev/null) || die "syft is unusable"

if igconf isset sbom_syft_config ; then
   SYFTCFG=$(realpath -e "$KSconf_sbom_syft_config") || die "Invalid syft config"
else
   die "No syft config"
fi

msg "SBOM: $SYFT scanning $rootfs"

syft -c "$SYFTCFG"  scan dir:"$rootfs" \
   --base-path "$rootfs" \
   --source-name "$KSconf_image_name" \
   --source-version "${KSconf_image_version}" \
   > "${outdir}/${KSconf_image_name}.sbom"
