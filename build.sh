#!/bin/bash
# ks-build: hard-fork driver (KS-only)
# - KS_* repo paths
# - KSconf_* configuration namespace
# - SBOM removed; keep only *.img / *.img.zst in deploy
# - robust conditionals (no command substitution inside [[ ]])

set -euo pipefail

# ---------------- KS repo layout ----------------
KS_TOP="$(readlink -f "$(dirname "$0")")"
KS_CONFIG_DIR="${KS_TOP}/config"
KS_DEVICE_DIR="${KS_TOP}/device"
KS_IMAGE_DIR="${KS_TOP}/image"
KS_PROFILE_DIR="${KS_TOP}/profile"
KS_META_DIR="${KS_TOP}/meta"
KS_META_HOOKS_DIR="${KS_TOP}/meta-hooks"
KS_TEMPLATES="${KS_TOP}/templates"
KS_HELPERS="${KS_TOP}/hooks"

# ---------------- Core helpers ------------------
source "${KS_TOP}/scripts/dependencies_check"
dependencies_check "${KS_TOP}/depends" || exit 1
source "${KS_TOP}/scripts/common"
source "${KS_TOP}/scripts/core"
source "${KS_TOP}/bin/ksconf"   # KS config/option loader

# ---------------- CLI ---------------------------
EXT_DIR=""
EXT_META=""
EXT_NS=""
EXT_NSDIR=""
EXT_NSMETA=""
INOPTIONS=""
INCONFIG="generic64-apt-simple"
ONLY_ROOTFS=0
ONLY_IMAGE=0

usage() {
cat <<-EOF >&2
Usage
  $(basename "$0") [options]

Options:
  [-c <config>]    Config name (under config/)
                   Default: $INCONFIG
  [-D <directory>] External dir to override in-tree config/device/image/profile/meta
  [-N <namespace>] Namespace subdir under -D for meta layers
  [-o <file>]      Shell fragment with KEY=VALUE overrides
  Developer
  [-r]             Stop after rootfs (post-build)
  [-i]             Skip rootfs, run hooks, generate image
EOF
}

while getopts "c:D:hiN:o:r" flag ; do
  case "$flag" in
    c) INCONFIG="$OPTARG" ;;
    h) usage ; exit 0 ;;
    D)
      EXT_DIR="$(python3 - <<'PY'
import os,sys
p=sys.argv[1]
print(os.path.realpath(p))
PY
"${OPTARG}")"
      [[ -d "$EXT_DIR" ]] || { usage ; die "Invalid external directory: $EXT_DIR" ; }
      ;;
    i) ONLY_IMAGE=1 ;;
    N) EXT_NS="$OPTARG" ;;
    o)
      INOPTIONS="$(python3 - <<'PY'
import os,sys
p=sys.argv[1]
print(os.path.realpath(p))
PY
"${OPTARG}")"
      [[ -f "$INOPTIONS" ]] || { usage ; die "Invalid options file: $INOPTIONS" ; }
      ;;
    r) ONLY_ROOTFS=1 ;;
    ?|*) usage ; exit 1 ;;
  esac
done

# ---------------- External meta / namespace -----
if [[ -n "${EXT_DIR}" && -d "${EXT_DIR}/meta" ]]; then
  EXT_META="${EXT_DIR}/meta"
fi
if [[ -n "${EXT_NS}" && -z "${EXT_DIR}" ]]; then
  die "External namespace supplied without external dir"
fi
if [[ -n "${EXT_NS}" && -n "${EXT_DIR}" ]]; then
  if [[ -d "${EXT_DIR}/${EXT_NS}" ]]; then
    EXT_NSDIR="${EXT_DIR}/${EXT_NS}"
  else
    die "External namespace dir ${EXT_NS} does not exist in ${EXT_DIR}"
  fi
  if [[ -d "${EXT_DIR}/${EXT_NS}/meta" ]]; then
    EXT_NSMETA="${EXT_DIR}/${EXT_NS}/meta"
  fi
fi

# ---------------- Resolve config path -----------
INCONFIG="${INCONFIG%.cfg}.cfg"
if [[ -n "${EXT_DIR}" && -f "${EXT_DIR}/config/${INCONFIG}" ]]; then
  KS_CONFIG_DIR="${EXT_DIR}/config"
elif [[ ! -f "${KS_CONFIG_DIR}/${INCONFIG}" ]]; then
  die "Can't resolve config file '${INCONFIG}'. Tried '${KS_CONFIG_DIR}/${INCONFIG}'${EXT_DIR:+ and '${EXT_DIR}/config/${INCONFIG}'}"
fi
CFG="${KS_CONFIG_DIR}/${INCONFIG}"

[[ -n "$EXT_META"   ]] && msg "External meta at $EXT_META"
[[ -n "$EXT_NSMETA" ]] && msg "External [$EXT_NS] meta at $EXT_NSMETA"

# Pass-thru for downstream layers
[[ -n "$EXT_DIR"   ]] && KSconf_ext_dir="$EXT_DIR"
[[ -n "$EXT_NSDIR" ]] && KSconf_ext_nsdir="$EXT_NSDIR"

msg "Reading $CFG with options [${INOPTIONS:-}]"

# User options first, then config/defaults, then options again
[[ -s "$INOPTIONS" ]] && apply_options "$INOPTIONS"
aggregate_config "$CFG"

# Required config keys
[[ -z ${KSconf_image_layout+x}   ]] && die "No image layout provided"
[[ -z ${KSconf_device_class+x}   ]] && die "No device class provided"
[[ -z ${KSconf_device_profile+x} ]] && die "No device profile provided"

# ---------------- Resolve device/image/profile roots -----------
if [[ -n "${EXT_DIR}" && -d "${EXT_DIR}/device/${KSconf_device_class}" ]]; then
  KS_DEVICE="${EXT_DIR}/device/${KSconf_device_class}"
else
  KS_DEVICE="${KS_DEVICE_DIR}/${KSconf_device_class}"
fi

if [[ -n "${EXT_DIR}" && -d "${EXT_DIR}/image/${KSconf_image_layout}" ]]; then
  KS_IMAGE="${EXT_DIR}/image/${KSconf_image_layout}"
else
  KS_IMAGE="${KS_IMAGE_DIR}/${KSconf_image_layout}"
fi

if [[ -n "${EXT_DIR}" && -f "${EXT_DIR}/profile/${KSconf_device_profile}" ]]; then
  KS_PROFILE="${EXT_DIR}/profile/${KSconf_device_profile}"
else
  KS_PROFILE="${KS_PROFILE_DIR}/${KSconf_device_profile}"
fi

for i in KS_DEVICE KS_IMAGE KS_PROFILE ; do
  msg "$i ${!i}"
  [[ -e "${!i}" ]] || die "$i is invalid: ${!i}"
done

# ---------------- Merge per-target options/defaults -----------
[[ -s "${KS_DEVICE}/config.options"    ]] && aggregate_options "device" "${KS_DEVICE}/config.options"
[[ -s "${KS_IMAGE}/config.options"     ]] && aggregate_options "image"  "${KS_IMAGE}/config.options"

[[ -s "${KS_DEVICE}/build.defaults"    ]] && aggregate_options "device" "${KS_DEVICE}/build.defaults"
[[ -s "${KS_IMAGE}/build.defaults"     ]] && aggregate_options "image"  "${KS_IMAGE}/build.defaults"
[[ -s "${KS_IMAGE}/provision.defaults" ]] && aggregate_options "image"  "${KS_IMAGE}/provision.defaults"

# Global defaults
aggregate_options "device" "${KS_DEVICE_DIR}/build.defaults"
aggregate_options "image"  "${KS_IMAGE_DIR}/build.defaults"
aggregate_options "image"  "${KS_IMAGE_DIR}/provision.defaults"
aggregate_options "sys"    "${KS_TOP}/sys-build.defaults"
aggregate_options "meta"   "${KS_META_DIR}/defaults"

# Final user overrides
[[ -s "$INOPTIONS" ]] && apply_options "$INOPTIONS"

# ---------------- APT keydir -------------------
if ksconf_isnset sys_apt_keydir ; then
  KSconf_sys_apt_keydir="${KSconf_sys_workdir}/keys"
  mkdir -p "$KSconf_sys_apt_keydir"
  [[ -d /usr/share/keyrings ]] && rsync -a /usr/share/keyrings/ "$KSconf_sys_apt_keydir"
  [[ -d "$HOME/.local/share/keyrings" ]] && rsync -a "$HOME/.local/share/keyrings/" "$KSconf_sys_apt_keydir"
  [[ -d "${KS_TOP}/keydir" ]] && rsync -a "${KS_TOP}/keydir/" "$KSconf_sys_apt_keydir"
fi
[[ -d "${KSconf_sys_apt_keydir}" ]] || die "apt keydir ${KSconf_sys_apt_keydir} is invalid"

# ---------------- Build env (export KSconf_*) --------------
ENV_ROOTFS=()
ENV_POST_BUILD=()

for v in $(compgen -A variable -X '!KSconf*') ; do
  case "$v" in
    KSconf_device_timezone)
      ENV_ROOTFS+=('--env' "${v}=${!v}")
      ENV_POST_BUILD+=("${v}=${!v}")
      ENV_ROOTFS+=('--env' "KSconf_device_timezone_area=${!v%%/*}")
      ENV_ROOTFS+=('--env' "KSconf_device_timezone_city=${!v##*/}")
      ENV_POST_BUILD+=("KSconf_device_timezone_area=${!v%%/*}")
      ENV_POST_BUILD+=("KSconf_device_timezone_city=${!v##*/}")
      ;;
    KSconf_sys_apt_proxy_http)
      if command -v curl >/dev/null 2>&1; then
        err=$(curl --head --silent --write-out "%{http_code}" --output /dev/null "${!v}" || true)
        msg "${err:-000} ${!v}"
      fi
      ENV_ROOTFS+=('--aptopt' "Acquire::http { Proxy \"${!v}\"; }")
      ENV_ROOTFS+=('--env' "${v}=${!v}")
      ;;
    KSconf_sys_apt_keydir)
      ENV_ROOTFS+=('--aptopt' "Dir::Etc::TrustedParts ${!v}")
      ENV_ROOTFS+=('--env' "${v}=${!v}")
      ;;
    KSconf_sys_apt_get_purge)
      if ksconf_isy "$v" ; then ENV_ROOTFS+=('--aptopt' "APT::Get::Purge true") ; fi
      ;;
    KSconf_ext_dir|KSconf_ext_nsdir)
      ENV_ROOTFS+=('--env' "${v}=${!v}")
      ENV_POST_BUILD+=("${v}=${!v}")
      if [[ -d "${!v}/bin" ]] ; then
        PATH="${!v}/bin:${PATH}"
        ENV_ROOTFS+=('--env' "PATH=$PATH")
        ENV_POST_BUILD+=("PATH=${PATH}")
      fi
      ;;
    *)
      ENV_ROOTFS+=('--env' "${v}=${!v}")
      ENV_POST_BUILD+=("${v}=${!v}")
      ;;
  esac
done

# Expose KS repo paths to layers
ENV_ROOTFS+=('--env' "KS_TOP=${KS_TOP}")
ENV_ROOTFS+=('--env' "KS_META_HOOKS_DIR=${KS_META_HOOKS_DIR}")
ENV_ROOTFS+=('--env' "KS_TEMPLATES=${KS_TEMPLATES}")
ENV_ROOTFS+=('--env' "KS_HELPERS=${KS_HELPERS}")

for i in KS_DEVICE KS_IMAGE KS_PROFILE ; do
  ENV_ROOTFS+=('--env' "${i}=${!i}")
  ENV_POST_BUILD+=("${i}=${!i}")
done

ENV_ROOTFS+=('--env' "PATH=${KS_TOP}/bin:$PATH")
mkdir -p "${KSconf_sys_workdir}/host/bin"
ENV_POST_BUILD+=("PATH=${KS_TOP}/bin:${KSconf_sys_workdir}/host/bin:${PATH}")

# ---------------- Layer selection ----------------
layer_push() {
  msg "Load layer [$1] $2"
  case "$1" in
    image)
      if [[ -s "${KS_IMAGE}/meta/$2.yaml" ]] ; then
        [[ -f "${KS_IMAGE}/meta/$2.defaults" ]] && aggregate_options "meta" "${KS_IMAGE}/meta/$2.defaults"
        ARGS_LAYERS+=('--config' "${KS_IMAGE}/meta/$2.yaml")
        return
      fi
      ;& # fallthrough to main
    main|auto)
      if [[ -n "$EXT_NSMETA" && -s "${EXT_NSMETA}/$2.yaml" ]] ; then
        [[ -f "${EXT_NSMETA}/$2.defaults" ]] && aggregate_options "meta" "${EXT_NSMETA}/$2.defaults"
        ARGS_LAYERS+=('--config' "${EXT_NSMETA}/$2.yaml")
      elif [[ -n "$EXT_META" && -s "${EXT_META}/$2.yaml" ]] ; then
        [[ -f "${EXT_META}/$2.defaults" ]] && aggregate_options "meta" "${EXT_META}/$2.defaults"
        ARGS_LAYERS+=('--config' "${EXT_META}/$2.yaml")
      elif [[ -s "${KS_META_DIR}/$2.yaml" ]] ; then
        [[ -f "${KS_META_DIR}/$2.defaults" ]] && aggregate_options "meta" "${KS_META_DIR}/$2.defaults"
        ARGS_LAYERS+=('--config' "${KS_META_DIR}/$2.yaml")
      else
        die "Invalid meta layer: $2"
      fi
      ;;
    *) die "Invalid layer scope" ;;
  esac
}

ARGS_LAYERS=()
load_profile() {  # scope, file
  [[ $# -eq 2 ]] || die "Load profile bad nargs"
  msg "Load profile $2"
  [[ -f "$2" ]] || die "Invalid profile: $2"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    layer_push "$1" "$line"
  done < "$2"
}

load_profile main   "$KS_PROFILE"
if ksconf_isset image_profile ; then
  load_profile image "${KS_IMAGE}/profile/${KSconf_image_profile}"
fi
if ksconf_isy device_ssh_user1 ; then
  layer_push auto net-apps/openssh-server
fi
layer_push auto sys-apps/finalize-upgrade

# ---------------- Hook runner -------------------
runh() {
  local hookdir
  hookdir="$(dirname "$1")"
  local hook
  hook="$(basename "$1")"
  shift 1
  msg "$hookdir"["$hook"] "$@"
  env -C "$hookdir" "${ENV_POST_BUILD[@]}" podman unshare "./$hook" "$@"
  local ret=$?
  [[ $ret -eq 0 ]] || die "Hook Error: [${hookdir}/${hook}] ($ret)"
}

# pre-build hooks
runh "${KS_DEVICE_DIR}/pre-build.sh"
runh "${KS_IMAGE_DIR}/pre-build.sh"
[[ -x "${KS_IMAGE}/pre-build.sh"  ]] && runh "${KS_IMAGE}/pre-build.sh"
[[ -x "${KS_DEVICE}/pre-build.sh" ]] && runh "${KS_DEVICE}/pre-build.sh"

# ---------------- Rootfs (bdebstrap) ------------
if [[ "${ONLY_IMAGE}" -ne 1 ]]; then
  rund "$KS_TOP" podman unshare bdebstrap \
    "${ARGS_LAYERS[@]}" \
    "${ENV_ROOTFS[@]}" \
    --force --verbose --debug \
    --name "${KSconf_image_name}" \
    --hostname "${KSconf_device_hostname}" \
    --output "${KSconf_sys_outputdir}" \
    --target "${KSconf_sys_target}"  \
    --setup-hook 'bin/runner setup "$@"' \
    --essential-hook 'bin/runner essential "$@"' \
    --customize-hook 'bin/runner customize "$@"' \
    --cleanup-hook 'bin/runner cleanup "$@"'
fi

# If target is a file (non-directory), we're done
if [[ -f "${KSconf_sys_target}" ]]; then
  msg "Exiting: non-directory target complete"
  exit 0
fi

# ---------------- Overlays ----------------------
[[ -d "${KS_IMAGE}/device/rootfs-overlay"  ]] && run podman unshare rsync -a "${KS_IMAGE}/device/rootfs-overlay/"  "${KSconf_sys_target}"
[[ -d "${KS_DEVICE}/device/rootfs-overlay" ]] && run podman unshare rsync -a "${KS_DEVICE}/device/rootfs-overlay/" "${KSconf_sys_target}"

# ---------------- post-build hooks --------------
[[ -x "${KS_IMAGE}/post-build.sh"  ]] && runh "${KS_IMAGE}/post-build.sh"  "${KSconf_sys_target}"
[[ -x "${KS_DEVICE}/post-build.sh" ]] && runh "${KS_DEVICE}/post-build.sh" "${KSconf_sys_target}"

# Stop here if only rootfs requested
[[ "${ONLY_ROOTFS}" -eq 1 ]] && exit 0

# ---------------- pre-image hook ----------------
if [[ -x "${KS_DEVICE}/pre-image.sh" ]]; then
  runh "${KS_DEVICE}/pre-image.sh" "${KSconf_sys_target}" "${KSconf_sys_outputdir}"
elif [[ -x "${KS_IMAGE}/pre-image.sh" ]]; then
  runh "${KS_IMAGE}/pre-image.sh" "${KSconf_sys_target}" "${KSconf_sys_outputdir}"
else
  die "no pre-image hook"
fi

# ---------------- Image generation --------------
GTMP="$(mktemp -d)"
trap 'rm -rf "$GTMP"' EXIT
mkdir -p "${KSconf_sys_deploydir}"

# progress viewer (pv) fallback
if command -v pv >/dev/null 2>&1; then
  PV_CMD=(pv -t -F 'Generating image...%t')
else
  PV_CMD=(cat)
fi

for f in "${KSconf_sys_outputdir}"/genimage*.cfg; do
  [[ -f "$f" ]] || continue
  run podman unshare env "${ENV_POST_BUILD[@]}" genimage \
    --rootpath "${KSconf_sys_target}" \
    --tmppath "$GTMP" \
    --inputpath "${KSconf_sys_outputdir}" \
    --outputpath "${KSconf_sys_outputdir}" \
    --loglevel=1 \
    --config "$f" | "${PV_CMD[@]}" || die "genimage error"
done

# ---------------- post-image hooks --------------
if [[ -x "${KS_DEVICE}/post-image.sh" ]]; then
  runh "${KS_DEVICE}/post-image.sh" "${KSconf_sys_deploydir}"
elif [[ -x "${KS_IMAGE}/post-image.sh" ]]; then
  runh "${KS_IMAGE}/post-image.sh" "${KSconf_sys_deploydir}"
else
  runh "${KS_IMAGE_DIR}/post-image.sh" "${KSconf_sys_deploydir}"
fi

# Keep only images
if [[ -d "${KSconf_sys_deploydir}" ]]; then
  find "${KSconf_sys_deploydir}" -type f ! -name '*.img' ! -name '*.img.zst' -delete || true
fi
