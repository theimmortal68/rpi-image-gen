#!/bin/bash

set -uo pipefail

KS_TOP=$(readlink -f "$(dirname "$0")")

source "${KS_TOP}/scripts/dependencies_check"
dependencies_check "${KS_TOP}/depends" || exit 1
source "${KS_TOP}/scripts/common"
source "${KS_TOP}/scripts/core"
source "${KS_TOP}/bin/igconf"


# Defaults
EXT_DIR=
EXT_META=
EXT_NS=
EXT_NSDIR=
EXT_NSMETA=
INOPTIONS=
INCONFIG=generic64-apt-simple
ONLY_ROOTFS=0
ONLY_IMAGE=0


usage()
{
cat <<-EOF >&2
Usage
  $(basename "$0") [options]

Root filesystem and image generation utility.

Options:
  [-c <config>]    Name of config file, location defaults to config/
                   Default: $INCONFIG
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
  Developer Options
  [-r]             Establish configuration, build rootfs, exit after post-build.
  [-i]             Establish configuration, skip rootfs, run hooks, generate image.
EOF
}


while getopts "c:D:hiN:o:r" flag ; do
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
      i)
         ONLY_IMAGE=1
         ;;
      N)
         EXT_NS="$OPTARG"
         ;;
      o)
         INOPTIONS=$(realpath -m "$OPTARG")
         [[ -f $INOPTIONS ]] || { usage ; die "Invalid options file: $INOPTIONS" ; }
         ;;
      r)
         ONLY_ROOTFS=1
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
IGTOP_CONFIG="${KS_TOP}/config"
IGTOP_DEVICE="${KS_TOP}/device"
IGTOP_IMAGE="${KS_TOP}/image"
IGTOP_PROFILE="${KS_TOP}/profile"
IGTOP_SBOM="${KS_TOP}/sbom"
META="${KS_TOP}/meta"
KS_META_HOOKS_DIR="${KS_TOP}/meta-hooks"
KS_TEMPLATES="${KS_TOP}/templates/rpi"


# Establish the top level directory hierarchy by detecting the config file
INCONFIG="${INCONFIG%.cfg}.cfg"
if [[ -d ${EXT_DIR} ]] && \
   [[ -f $(realpath -e ${EXT_DIR}/config/${INCONFIG} 2>/dev/null) ]] ; then
   IGTOP_CONFIG="${EXT_DIR}/config"
else
   __IC=$(basename "$INCONFIG")
   if realpath -e "${IGTOP_CONFIG}/${__IC}" > /dev/null 2>&1  ; then
      INCONFIG="$__IC"
   else
      die "Can't resolve config file path for '${INCONFIG}'. Need -D?"
   fi
fi
CFG=$(realpath -e "${IGTOP_CONFIG}/${INCONFIG}" 2>/dev/null) || \
   die "Bad config spec: $IGTOP_CONFIG : $INCONFIG"


[[ -d $EXT_META ]] && msg "External meta at $EXT_META"
[[ -d $EXT_NSMETA ]] && msg "External [$EXT_NS] meta at $EXT_NSMETA"


# Set via cmdline only
[[ -d $EXT_DIR ]] && KSconf_ext_dir="$EXT_DIR"
[[ -d $EXT_NSDIR ]] && KSconf_ext_nsdir="$EXT_NSDIR"


msg "Reading $CFG with options [$INOPTIONS]"

# Load options(1) to perform explicit set/unset
[[ -s "$INOPTIONS" ]] && apply_options "$INOPTIONS"


# Merge config
aggregate_config "$CFG"


# Mandatory for subsequent parsing
[[ -z ${KSconf_image_layout+x} ]] && die "No image layout provided"
[[ -z ${KSconf_device_class+x} ]] && die "No device class provided"
[[ -z ${KSconf_device_profile+x} ]] && die "No device profile provided"


# Internalise hierarchy paths, prioritising the external sub-directory tree
[[ -d $EXT_DIR ]] && KS_DEVICE=$(realpath -e "${EXT_DIR}/device/$KSconf_device_class" 2>/dev/null)
: ${KS_DEVICE:=${IGTOP_DEVICE}/$KSconf_device_class}

[[ -d $EXT_DIR ]] && KS_IMAGE=$(realpath -e "${EXT_DIR}/image/$KSconf_image_layout" 2>/dev/null)
: ${KS_IMAGE:=${IGTOP_IMAGE}/$KSconf_image_layout}

[[ -d $EXT_DIR ]] && KS_PROFILE=$(realpath -e "${EXT_DIR}/profile/$KSconf_device_profile" 2>/dev/null)
: ${KS_PROFILE:=${IGTOP_PROFILE}/$KSconf_device_profile}


# Final path validation
for i in KS_DEVICE KS_IMAGE KS_PROFILE ; do
   msg "$i ${!i}"
   realpath -e ${!i} > /dev/null 2>&1 || die "$i is invalid"
done


# Merge config options for selected device and image
[[ -s ${KS_DEVICE}/config.options ]] && aggregate_options "device" ${KS_DEVICE}/config.options
[[ -s ${KS_IMAGE}/config.options ]] && aggregate_options "image" ${KS_IMAGE}/config.options


# Merge defaults for selected device and image
[[ -s ${KS_DEVICE}/build.defaults ]] && aggregate_options "device" ${KS_DEVICE}/build.defaults
[[ -s ${KS_IMAGE}/build.defaults ]] && aggregate_options "image" ${KS_IMAGE}/build.defaults
[[ -s ${KS_IMAGE}/provision.defaults ]] && aggregate_options "image" ${KS_IMAGE}/provision.defaults


# Merge remaining defaults
aggregate_options "device" ${IGTOP_DEVICE}/build.defaults
aggregate_options "image" ${IGTOP_IMAGE}/build.defaults
aggregate_options "image" ${IGTOP_IMAGE}/provision.defaults
aggregate_options "sys" ${KS_TOP}/sys-build.defaults
aggregate_options "sbom" ${IGTOP_SBOM}/defaults
aggregate_options "meta" ${META}/defaults


# Load options(2) for final overrides
[[ -s "$INOPTIONS" ]] && apply_options "$INOPTIONS"


# Assemble APT keys
if igconf_isnset sys_apt_keydir ; then
   KSconf_sys_apt_keydir="${KSconf_sys_workdir}/keys"
   mkdir -p "$KSconf_sys_apt_keydir"
   [[ -d /usr/share/keyrings ]] && rsync -a /usr/share/keyrings/ $KSconf_sys_apt_keydir
   [[ -d "$USER/.local/share/keyrings" ]] && rsync -a "$USER/.local/share/keyrings/" $KSconf_sys_apt_keydir
   rsync -a "$KS_TOP/keydir/" $KSconf_sys_apt_keydir
fi
[[ -d $KSconf_sys_apt_keydir ]] || die "apt keydir $KSconf_sys_apt_keydir is invalid"


# Assemble environment for rootfs and image creation, propagating IG variables
# to rootfs and post-build stages as appropriate.
ENV_ROOTFS=()
ENV_POST_BUILD=()
for v in $(compgen -A variable -X '!IGconf*') ; do
   case $v in
      KSconf_device_timezone)
         ENV_ROOTFS+=('--env' ${v}="${!v}")
         ENV_POST_BUILD+=(${v}="${!v}")
         ENV_ROOTFS+=('--env' KSconf_device_timezone_area="${!v%%/*}")
         ENV_ROOTFS+=('--env' KSconf_device_timezone_city="${!v##*/}")
         ENV_POST_BUILD+=(KSconf_device_timezone_area="${!v%%/*}")
         ENV_POST_BUILD+=(KSconf_device_timezone_city="${!v##*/}")
         ;;
      KSconf_sys_apt_proxy_http)
         err=$(curl --head --silent --write-out "%{http_code}" --output /dev/null "${!v}")
         [[ $? -ne 0 ]] && die "unreachable proxy: ${!v}"
         msg "$err ${!v}"
         ENV_ROOTFS+=('--aptopt' "Acquire::http { Proxy \"${!v}\"; }")
         ENV_ROOTFS+=('--env' ${v}="${!v}")
         ;;
      KSconf_sys_apt_keydir)
         ENV_ROOTFS+=('--aptopt' "Dir::Etc::TrustedParts ${!v}")
         ENV_ROOTFS+=('--env' ${v}="${!v}")
         ;;
      KSconf_sys_apt_get_purge)
         if igconf_isy $v ; then ENV_ROOTFS+=('--aptopt' "APT::Get::Purge true") ; fi
         ;;
      KSconf_ext_dir|KSconf_ext_nsdir )
         ENV_ROOTFS+=('--env' ${v}="${!v}")
         ENV_POST_BUILD+=(${v}="${!v}")
         if [ -d "${!v}/bin" ] ; then
            PATH="${!v}/bin:${PATH}"
            ENV_ROOTFS+=('--env' PATH="$PATH")
            ENV_POST_BUILD+=(PATH="${PATH}")
         fi
         ;;

      *)
         ENV_ROOTFS+=('--env' ${v}="${!v}")
         ENV_POST_BUILD+=(${v}="${!v}")
         ;;
   esac
done
ENV_ROOTFS+=('--env' KS_TOP=$KS_TOP)
ENV_ROOTFS+=('--env' KS_META_HOOKS_DIR=$KS_META_HOOKS_DIR)
ENV_ROOTFS+=('--env' KS_TEMPLATES=$KS_TEMPLATES)

for i in KS_DEVICE KS_IMAGE KS_PROFILE ; do
   ENV_ROOTFS+=('--env' ${i}="${!i}")
   ENV_POST_BUILD+=(${i}="${!i}")
done


# Final PATH setup
ENV_ROOTFS+=('--env' PATH="${KS_TOP}/bin:$PATH")
mkdir -p ${KSconf_sys_workdir}/host/bin
ENV_POST_BUILD+=(PATH="${KS_TOP}/bin:${KSconf_sys_workdir}/host/bin:${PATH}")


# Load layer default settings and append layer to list
layer_push()
{
   msg "Load layer [$1] $2"
   case "$1" in
      image)
         if [[ -s "${KS_IMAGE}/meta/$2.yaml" ]] ; then
            [[ -f "${KS_IMAGE}/meta/$2.defaults" ]] && \
               aggregate_options "meta" "${KS_IMAGE}/meta/$2.defaults"
            ARGS_LAYERS+=('--config' "${KS_IMAGE}/meta/$2.yaml")
            return
         fi
         ;& # image layer can pull in core layers, but not vice versa

      main|auto)
         if [[ -n $EXT_NSMETA && -s "${EXT_NSMETA}/$2.yaml" ]] ; then
            [[ -f "${EXT_NSMETA}/$2.defaults" ]] && \
               aggregate_options "meta" "${EXT_NSMETA}/$2.defaults"
            ARGS_LAYERS+=('--config' "${EXT_NSMETA}/$2.yaml")

         elif [[ -n $EXT_META && -s "${EXT_META}/$2.yaml" ]] ; then
            [[ -f "${EXT_META}/$2.defaults" ]] && \
               aggregate_options "meta" "${EXT_META}/$2.defaults"
            ARGS_LAYERS+=('--config' "${EXT_META}/$2.yaml")

         elif [[ -s "${META}/$2.yaml" ]] ; then
            [[ -f "${META}/$2.defaults" ]] && \
               aggregate_options "meta" "${META}/$2.defaults"
            ARGS_LAYERS+=('--config' "${META}/$2.yaml")
         else
            die "Invalid meta layer specifier: $2 (not found)"
         fi
         ;;
      *)
         die "Invalid layer scope" ;;
   esac
}


ARGS_LAYERS=()
load_profile() {
   [[ $# -eq 2 ]] || die "Load profile bad nargs"
   msg "Load profile $2"
   [[ -f $2 ]] || die "Invalid profile: $2"
   while read -r line; do
      [[ "$line" =~ ^#.*$ ]] && continue
      [[ "$line" =~ ^$ ]] && continue
      layer_push "$1" "$line"
   done < "$2"
}


# Assemble meta layers from main profile
load_profile main "$KS_PROFILE"


# Add layers from image profile
if igconf_isset image_profile ; then
   load_profile image "${KS_IMAGE}/profile/${KSconf_image_profile}"
fi


# Auto-selected layers
if igconf_isy device_ssh_user1 ; then
   layer_push auto net-apps/openssh-server
fi

# Ensure finalize-upgrade runs LAST (after any auto-appended layers like SSH)
# This assumes you have meta/sys-apps/finalize-upgrade.yaml in your repo.
# If you keep metas in an external namespace, layer_push will resolve those too.
layer_push auto sys-apps/finalize-upgrade

# hook execution
runh()
{
   local hookdir=$(dirname "$1")
   local hook=$(basename "$1")
   shift 1
   msg "$hookdir"["$hook"] "$@"
   env -C $hookdir "${ENV_POST_BUILD[@]}" podman unshare ./"$hook" "$@"
   ret=$?
   if [[ $ret -ne 0 ]]
   then
      die "Hook Error: ["$hookdir"/"$hook"] ($ret)"
   fi
}


# pre-build: hooks - common
runh ${IGTOP_DEVICE}/pre-build.sh
runh ${IGTOP_IMAGE}/pre-build.sh


# pre-build: hooks - image layout then device
if [ -x ${KS_IMAGE}/pre-build.sh ] ; then
   runh ${KS_IMAGE}/pre-build.sh
fi
if [ -x ${KS_DEVICE}/pre-build.sh ] ; then
   runh ${KS_DEVICE}/pre-build.sh
fi


# Generate rootfs
[[ $ONLY_IMAGE = 1 ]] && true || rund "$KS_TOP" podman unshare bdebstrap \
   "${ARGS_LAYERS[@]}" \
   "${ENV_ROOTFS[@]}" \
   --force \
   --verbose \
   --debug \
   --name "$KSconf_image_name" \
   --hostname "$KSconf_device_hostname" \
   --output "$KSconf_sys_outputdir" \
   --target "$KSconf_sys_target"  \
   --setup-hook 'bin/runner setup "$@"' \
   --essential-hook 'bin/runner essential "$@"' \
   --customize-hook 'bin/runner customize "$@"' \
   --cleanup-hook 'bin/runner cleanup "$@"'


[[ -f "$KSconf_sys_target" ]] && { msg "Exiting as non-directory target complete" ; exit 0 ; }


# post-build: apply rootfs overlays - image layout then device
if [ -d ${KS_IMAGE}/device/rootfs-overlay ] ; then
   run podman unshare rsync -a ${KS_IMAGE}/device/rootfs-overlay/ ${KSconf_sys_target}
fi
if [ -d ${KS_DEVICE}/device/rootfs-overlay ] ; then
   run podman unshare rsync -a ${KS_DEVICE}/device/rootfs-overlay/ ${KSconf_sys_target}
fi


# post-build: hooks - image layout then device
if [ -x ${KS_IMAGE}/post-build.sh ] ; then
   runh ${KS_IMAGE}/post-build.sh ${KSconf_sys_target}
fi
if [ -x ${KS_DEVICE}/post-build.sh ] ; then
   runh ${KS_DEVICE}/post-build.sh ${KSconf_sys_target}
fi


[[ $ONLY_ROOTFS = 1 ]] && exit $?


# pre-image: hooks - device has priority over image layout
if [ -x ${KS_DEVICE}/pre-image.sh ] ; then
   runh ${KS_DEVICE}/pre-image.sh ${KSconf_sys_target} ${KSconf_sys_outputdir}
elif [ -x ${KS_IMAGE}/pre-image.sh ] ; then
   runh ${KS_IMAGE}/pre-image.sh ${KSconf_sys_target} ${KSconf_sys_outputdir}
else
   die "no pre-image hook"
fi


# SBOM
if [ -x ${IGTOP_SBOM}/gen.sh ] ; then
   runh ${IGTOP_SBOM}/gen.sh ${KSconf_sys_target} ${KSconf_sys_outputdir}
fi


GTMP=$(mktemp -d)
trap 'rm -rf $GTMP' EXIT
mkdir -p "$KSconf_sys_deploydir"


# Generate image(s)
for f in "${KSconf_sys_outputdir}"/genimage*.cfg; do
   [[ -f "$f" ]] || continue
   run podman unshare env "${ENV_POST_BUILD[@]}" genimage \
      --rootpath ${KSconf_sys_target} \
      --tmppath $GTMP \
      --inputpath ${KSconf_sys_outputdir}   \
      --outputpath ${KSconf_sys_outputdir} \
      --loglevel=1 \
      --config $f | pv -t -F 'Generating image...%t' || die "genimage error"
done


# post-image: hooks - device has priority over image layout
if [ -x ${KS_DEVICE}/post-image.sh ] ; then
   runh ${KS_DEVICE}/post-image.sh $KSconf_sys_deploydir
elif [ -x ${KS_IMAGE}/post-image.sh ] ; then
   runh ${KS_IMAGE}/post-image.sh $KSconf_sys_deploydir
else
   runh ${IGTOP_IMAGE}/post-image.sh $KSconf_sys_deploydir
fi
