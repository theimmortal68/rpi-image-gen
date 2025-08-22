#!/bin/bash
# ks-build: hard-fork driver (KS-only)
# - KS_* repo paths
# - KSconf_* configuration namespace
# - SBOM removed; keep only *.img / *.img.zst

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
EXT_DIR=
EXT_META=
EXT_NS=
EXT_NSDIR=
EXT_NSMETA=
INOPTIONS=
INCONFIG=generic64-apt-simple
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
      EXT_DIR="$(realpath -m "$OPTARG")"
      [[ -d "$EXT_DIR" ]] || { usage ; die "Invalid external directory: $EXT_DIR" ; }
      ;;
    i) ONLY_IMAGE=1 ;;
    N) EXT_NS="$OPTARG" ;;
    o)
      INOPTIONS="$(realpath -m "$OPTARG")"
      [[ -f "$INOPTIONS" ]] || { usage ; die "Invalid options file: $INOPTIONS" ; }
      ;;
    r) ONLY_ROOTFS=1 ;;
    ?|*) usage ; exit 1 ;;
  esac
done

# External meta/namespace dirs (no failing realpath -e)
if [[ -n "${EXT_DIR}" && -d "${EXT_DIR}/meta" ]]; then
  EXT_META="${EXT_DIR}/meta"
fi
if [[ -n "${EXT_DIR}" && -n "${EXT_NS}" ]]; then
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

# Prefer external override when provided, else fall back to in-tree.
if [[ -n "$EXT_DIR" && -d "$EXT_DIR" && -f "$EXT_DIR/config/$INCONFIG" ]]; then
  KS_CONFIG_DIR="$EXT_DIR/config"
elif [[ -f "$KS_CONFIG_DIR/$INCONFIG" ]]; then
  : # keep KS_CONFIG_DIR as-is
else
  die "Can't resolve config file '$INCONFIG'. Tried: '$KS_CONFIG_DIR/$INCONFIG'${EXT_DIR:+ and '$EXT_DIR/config/$INCONFIG'}"
fi

# Resolved config path (no subshell; bash -e friendly)
CFG="$KS_CONFIG_DIR/$INCONFIG"

[[ -n "${EXT_META:-}" ]]   && msg "External meta at $EXT_META"
[[ -n "${EXT_NSMETA:-}" ]] && msg "External [$EXT_NS] meta at $EXT_NSMETA"

# Pass-thru for downstream layers
[[ -n "${EXT_DIR:-}"   ]] && KSconf_ext_dir="$EXT_DIR"
[[ -n "${EXT_NSDIR:-}" ]] && KSconf_ext_nsdir="$EXT_NSDIR"

msg "Reading $CFG with options [${INOPTIONS:-}]"

# User options first, then config/defaults, then options again
[[ -s "${INOPTIONS:-}" ]] && apply_options "$INOPTIONS"
aggregate_config "$CFG"

# Required config keys
[[ -z ${KSconf_image_layout+x}  ]] && die "No image layout provided"
[[ -]()]()
