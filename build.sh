#!/bin/bash

set -uo pipefail

IGTOP=$(readlink -f "$(dirname "$0")")

source "${IGTOP}/scripts/common"
source "${IGTOP}/scripts/dependencies_check"
dependencies_check "${IGTOP}/depends"


usage()
{
cat <<-EOF >&2
Usage
  $(basename "$0") [options]

Root filesystem and image generation utility.

Options:
  [-c <config>]    Name of config file, location defaults to config/
  [-D <directory>] Directory that takes precedence over the default in-tree
                   hierarchy when searching for config files, profiles, meta
                   layers and image layouts.
  [-N <namespace>] Optional namespace to specify an additional sub-directory
                   hierarchy within the directory provided by -D of where to
                   search for meta layers.
  [-o <file>]      Path to shell-style fragment specifying variables as
                   key=value. These variables can override the defaults, those
                   set by the config file, or provide completely new variables
                   available to both rootfs and image generation stages.
EOF
}


# Arg parser and defaults
EXT_DIR=
EXT_META=
EXT_NS=
EXT_NSDIR=
EXT_NSMETA=
INOPTIONS=
INCONFIG=generic64-apt-simple

while getopts "c:D:hN:o:" flag ; do
   case "$flag" in
      c)
         INCONFIG="$OPTARG"
         ;;
      h)
         usage ; exit 0
         ;;
      D)
         EXT_DIR=$(realpath -m "$OPTARG")
         [[ -d $EXT_DIR ]] || { usage ; die "Invalid external directory: $EXT_DIR" ; }
         ;;
      N)
         EXT_NS="$OPTARG"
         ;;
      o)
         INOPTIONS=$(realpath -m "$OPTARG")
         [[ -s $INOPTIONS ]] || { usage ; die "Invalid options file: $INOPTIONS" ; }
         ;;
      ?|*)
         usage ; exit 1
         ;;
   esac
done


[[ -d $EXT_DIR ]] && EXT_META=$(realpath -e "${EXT_DIR}/meta" 2>/dev/null)

[[ -n $EXT_NS && ! -d $EXT_DIR ]] && die "External namespace supplied without external dir"

if [[ -d $EXT_DIR && -n $EXT_NS ]] ; then
   EXT_NSDIR=$(realpath -e "${EXT_DIR}/$EXT_NS" 2>/dev/null)
   [[ -d $EXT_NSDIR ]] || die "External namespace dir $EXT_NS does not exist in $EXT_DIR"
   EXT_NSMETA=$(realpath -e "${EXT_DIR}/$EXT_NS/meta" 2>/dev/null)
fi


# Constants
IGTOP_CONFIG="${IGTOP}/config"
IGTOP_BOARD="${IGTOP}/board"
IGTOP_IMAGE="${IGTOP}/image"
IGTOP_PROFILE="${IGTOP}/profile"
META="${IGTOP}/meta"
META_HOOKS="${IGTOP}/meta-hooks"
RPI_TEMPLATES="${IGTOP}/templates/rpi"


# Establish the top level directory hierarchy by first reading the config
if [[ -d "${EXT_DIR}/config" && -s "${EXT_DIR}/config/${INCONFIG}.cfg" ]] ; then
   IGTOP_CONFIG="${EXT_DIR}/config"
elif [[ -s "${IGTOP}/config/${INCONFIG}.cfg" ]] ; then
   IGTOP_CONFIG="${IGTOP}/config"
else
   die "config "$INCONFIG" not found or invalid"
fi

msg "Reading $INCONFIG from $IGTOP_CONFIG with options [$INOPTIONS]"
[[ -d $EXT_META ]] && msg "External meta at $EXT_META"
[[ -d $EXT_NSMETA ]] && msg "External [$EXT_NS] meta at $EXT_NSMETA"


# Defaults
IGconf_target_board=pi5
IG_image_name="${IGconf_target_board}-$(echo "${INCONFIG}"|sed -s 's|\/|\-|g')"
IGconf_image_suffix=img
IGconf_image_compression=none
unset IGconf_apt_proxy
IGconf_target_hostname=raspberrypi
IGconf_first_user_name=pi
unset IGconf_first_user_pass
IGconf_locale_default="en_GB.UTF-8"
IGconf_keyboard_keymap=gb
IGconf_keyboard_layout="English (UK)"
IGconf_timezone_default="Europe/London"
unset IGconf_ext_dir
unset IGconf_ext_nsdir


# Provide external directory paths
[[ -d $EXT_DIR ]] && IGconf_ext_dir="$EXT_DIR"
[[ -d $EXT_NSDIR ]] && IGconf_ext_nsdir="$EXT_NSDIR"


read_config_section image "${IGTOP_CONFIG}/${INCONFIG}.cfg"
read_config_section system "${IGTOP_CONFIG}/${INCONFIG}.cfg"
read_config_section target "${IGTOP_CONFIG}/${INCONFIG}.cfg"


# Config must provide
[[ -z ${IGconf_image_layout+x} ]] && die "Config has no image layout"
[[ -z ${IGconf_system_profile+x} ]] && die "Config has no system profile"


# Internalise hierarchy paths, prioritising the external sub-directory tree
[[ -d $EXT_DIR ]] && IGBOARD=$(realpath -e "${EXT_DIR}/board/$IGconf_target_board" 2>/dev/null)
: ${IGBOARD:=${IGTOP_BOARD}/$IGconf_target_board}

[[ -d $EXT_DIR ]] && IGIMAGE=$(realpath -e "${EXT_DIR}/image/$IGconf_image_layout" 2>/dev/null)
: ${IGIMAGE:=${IGTOP_IMAGE}/$IGconf_image_layout}

[[ -d $EXT_DIR ]] && IGPROFILE=$(realpath -e "${EXT_DIR}/profile/$IGconf_system_profile" 2>/dev/null)
: ${IGPROFILE:=${IGTOP_PROFILE}/$IGconf_system_profile}


# Final path validation
for i in IGBOARD IGIMAGE IGPROFILE ; do
   msg "$i ${!i}"
   realpath -e ${!i} > /dev/null 2>&1 || die "$i is invalid"
done


# Load options
[[ -s "$INOPTIONS" ]] && read_options "$INOPTIONS"


# Remaining defaults
: "${IGconf_work_dir:=${IGTOP}/work/${IGconf_image_name}}"
: "${IGconf_image_outputdir:=${IGconf_work_dir}/artefacts}"
: "${IGconf_image_deploydir:=${IGconf_image_outputdir}/deploy}"


# Assemble environment for rootfs and image creation, propagating all
# all IG variables to both stages. Others as appropriate.
ENV_ROOTFS=()
ENV_IMAGE=()
for v in $(compgen -A variable -X '!IGconf*') ; do
   # Translate any legacy variables here
   case $v in
      IGconf_timezone_default)
         ENV_ROOTFS+=('--env' IGconf_timezone_area="${!v%%/*}")
         ENV_ROOTFS+=('--env' IGconf_timezone_city="${!v##*/}")
         ENV_IMAGE+=(IGconf_timezone_area="${!v%%/*}")
         ENV_IMAGE+=(IGconf_timezone_city="${!v##*/}")
         ;;
      IGconf_apt_proxy)
         ENV_ROOTFS+=('--env' IGconf_apt_proxy_http="${!v}")
         ENV_IMAGE+=(IGconf_apt_proxy_http="${!v}")
         ;;
      *)
         ENV_ROOTFS+=('--env' ${v}="${!v}")
         ENV_IMAGE+=(${v}="${!v}")
         ;;
   esac
done
ENV_ROOTFS+=('--env' IGTOP=$IGTOP)
ENV_ROOTFS+=('--env' META_HOOKS=$META_HOOKS)
ENV_ROOTFS+=('--env' RPI_TEMPLATES=$RPI_TEMPLATES)


# Assemble meta layers from profile
ARGS_LAYERS=()
while read -r line; do
   [[ "$line" =~ ^#.*$ ]] && continue
   [[ "$line" =~ ^$ ]] && continue
   if [[ -n $EXT_NSMETA && -s ${EXT_NSMETA}/$line.yaml ]] ; then
      ARGS_LAYERS+=('--config' "${EXT_NSMETA}/$line.yaml")
   elif [[ -n $EXT_META && -s ${EXT_META}/$line.yaml ]] ; then
      ARGS_LAYERS+=('--config' "${EXT_META}/$line.yaml")
   elif [[ -s ${META}/$line.yaml ]] ; then
      ARGS_LAYERS+=('--config' "${META}/$line.yaml")
   else
      die "Invalid meta specifier: $line (not found)"
   fi
done < "${IGPROFILE}"


# Generate rootfs
run podman unshare bdebstrap \
   "${ARGS_LAYERS[@]}" \
   "${ENV_ROOTFS[@]}" \
   --name "$IGconf_image_name" \
   --hostname "$IGconf_target_hostname" \
   --output "$IGconf_image_outputdir" \
   --target "${IGconf_work_dir}/rootfs" \
   --setup-hook '$IGTOP/scripts/runner setup $IGTOP/scripts/bdebstrap "${IGconf_work_dir}/rootfs"' \
   --essential-hook '$IGTOP/scripts/runner essential $IGTOP/scripts/bdebstrap "${IGconf_work_dir}/rootfs"' \
   --customize-hook '$IGTOP/scripts/runner customize $IGTOP/scripts/bdebstrap "${IGconf_work_dir}/rootfs"' \
   --cleanup-hook '$IGTOP/scripts/runner cleanup $IGTOP/scripts/bdebstrap "${IGconf_work_dir}/rootfs"'


# hook execution
runh()
{
   local hookdir=$(dirname "$1")
   local hook=$(basename "$1")
   shift 1
   msg "$hookdir"["$hook"] "$@"
   env -C $hookdir "${ENV_IMAGE[@]}" ./"$hook" "$@"
   ret=$?
   if [[ $ret -ne 0 ]]
   then
      die "Hook Error: ["$hookdir"/"$hook"] ($ret)"
   fi
}



# post-build: apply rootfs overlays - image layout then board
if [ -d ${IGIMAGE}/rootfs-overlay ] ; then
   run rsync -a ${IGIMAGE}/rootfs-overlay/ ${IGconf_work_dir}/rootfs
fi
if [ -d ${IGBOARD}/rootfs-overlay ] ; then
   run rsync -a ${IGBOARD}/rootfs-overlay/ ${IGconf_work_dir}/rootfs
fi


# post-build: hooks - image layout then board
if [ -x ${IGIMAGE}/post-build.sh ] ; then
   runh ${IGIMAGE}/post-build.sh ${IGconf_work_dir}/rootfs
fi
if [ -x ${IGBOARD}/post-build.sh ] ; then
   runh ${IGBOARD}/post-build.sh ${IGconf_work_dir}/rootfs
fi


# pre-image: hooks - board has priority over image layout
if [ -x ${IGBOARD}/pre-image.sh ] ; then
   runh ${IGBOARD}/pre-image.sh ${IGconf_work_dir}/rootfs ${IGconf_work_dir}
elif [ -x ${IGIMAGE}/pre-image.sh ] ; then
   runh ${IGIMAGE}/pre-image.sh ${IGconf_work_dir}/rootfs ${IGconf_work_dir}
else
   die "no pre-image hook"
fi


GTMP=$(mktemp -d)
trap 'rm -rf $GTMP' EXIT
mkdir -p "$IGconf_image_deploydir"


# Generate image(s)
for f in "${IGconf_work_dir}"/genimage*.cfg; do
   run podman unshare genimage \
      --rootpath ${IGconf_work_dir}/rootfs \
      --tmppath $GTMP \
      --inputpath ${IGconf_work_dir}   \
      --outputpath ${IGconf_image_outputdir} \
      --loglevel=10 \
      --config $f
done


# post-image: hooks - board has priority over image layout
if [ -x ${IGBOARD}/post-image.sh ] ; then
   runh ${IGBOARD}/post-image.sh $IGconf_image_deploydir
elif [ -x ${IGIMAGE}/post-image.sh ] ; then
   runh ${IGIMAGE}/post-image.sh $IGconf_image_deploydir
else
   :
fi
