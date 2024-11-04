#!/bin/bash

set -eo pipefail

IGTOP=$(readlink -f $(dirname "$0"))

WORKROOT=${STAGE_WORK_DIR}


# TODO need top level selectors for:
#  external dir
#  external namespace
# These will be used to override/augment paths for sub-directories to
# facilitate third-party customisation, e.g.
# /<dir>/
#        meta/<namespace>/ [augment]
#        profile/          [override]
#        config/           [override]
#        board/            [override]
#        image/            [augment]

IGPROFILE_TOP=${IGTOP}/profile
IGCONFIG_TOP=${IGTOP}/config
IGBOARD_TOP=${IGTOP}/board


# Internalise directory structure variables
META=$IGTOP/meta
META_HOOKS=$IGTOP/meta-hooks
RPI_TEMPLATES=$IGTOP/templates/rpi


# TODO get from top level arg, eg -p generic64-min-ab
INCONFIG=generic64-apt-ab
test -s ${IGCONFIG_TOP}/${INCONFIG}.cfg || (>&2 echo ${IGCONFIG_TOP}/${INCONFIG}.cfg is invalid; exit 1)


# Config defaults
IGconf_board=pi5


# Read and validate config
read_config_section image ${IGCONFIG_TOP}/${INCONFIG}.cfg
read_config_section system ${IGCONFIG_TOP}/${INCONFIG}.cfg
[[ -z ${IGconf_layout+x} ]] && (>&2 echo config has no image layout; exit 1)
[[ -z ${IGconf_profile+x} ]] && (>&2 echo config has no profile; exit 1)

test -d $IGTOP/image/$IGconf_layout || (>&2 echo disk layout "$IGconf_layout" is invalid; exit 1)
test -s $IGTOP/image/$IGconf_layout/genimage.cfg.in || (>&2 echo "$IGconf_layout" has no genimage cfg; exit 1)
test -f $IGTOP/profile/$IGconf_profile || (>&2 echo profile "$IGconf_profile" is invalid; exit 1)
test -d $IGTOP/board/$IGconf_board || (>&2 echo board "$IGconf_board" is invalid; exit 1)


# Export this set of config variables
export IGconf_board
export IGconf_layout
export IGconf_deploydir=$WORKROOT/deploy


# Read and validate options - TODO read file via top level
# These could be aggregated with the config file if required. For now, retain
# parity with pi-gen variable names.
read_options << EOF
APT_PROXY=$APT_PROXY
LOCALE_DEFAULT=$LOCALE_DEFAULT
TIMEZONE_DEFAULT=$TIMEZONE_DEFAULT
FIRST_USER_NAME=$FIRST_USER_NAME
FIRST_USER_PASS=$FIRST_USER_PASS
EOF


# Assemble bootstrap environment and propagate options
ARGS_ENV=()
ARGS_ENV+=('--env' META_HOOKS=$META_HOOKS)
ARGS_ENV+=('--env' RPI_TEMPLATES=$RPI_TEMPLATES)

IGopt_bootstrap=(
   IGopt_APT_PROXY
   IGopt_LOCALE_DEFAULT
   IGopt_TIMEZONE_DEFAULT
   IGopt_FIRST_USER_NAME
   IGopt_FIRST_USER_PASS
)
for option in "${IGopt_bootstrap[@]}" ; do
   case $option in
      IGopt_TIMEZONE_DEFAULT)
         ARGS_ENV+=('--env' IGopt_TIMEZONE_AREA="${IGopt_TIMEZONE_DEFAULT%%/*}")
         ARGS_ENV+=('--env' IGopt_TIMEZONE_CITY="${IGopt_TIMEZONE_DEFAULT##*/}")
         ;;
      *)
         ARGS_ENV+=('--env' ${option}=${!option})
         ;;
   esac
done


# Assemble meta layers from profile
ARGS_LAYERS=()
while read -r line; do
   [[ "$line" =~ ^#.*$ ]] && continue
   [[ "$line" =~ ^$ ]] && continue
   test -f $META/$line.yaml || (>&2 echo invalid meta specifier: "$line"; exit 1)
   ARGS_LAYERS+=('--config' $META/$line.yaml)
done < $IGTOP/profile/$IGconf_profile


# Generate rootfs
podman unshare bdebstrap \
   "${ARGS_LAYERS[@]}" \
   "${ARGS_ENV[@]}" \
   --name $IMG_NAME \
   --hostname $TARGET_HOSTNAME \
   --output-base-dir ${WORKROOT}/bdebstrap \
   --target ${WORKROOT}/rootfs


# post-build: apply rootfs overlays - image layout then board
if [ -d $IGTOP/image/$IGconf_layout/rootfs-overlay ] ; then
   echo "$IGconf_layout:rootfs-overlay"
   rsync -a $IGTOP/image/$IGconf_layout/rootfs-overlay/ ${WORKROOT}/rootfs
fi
if [ -d $IGTOP/board/$IGconf_board/rootfs-overlay ] ; then
   echo "$IGconf_board:rootfs-overlay"
   rsync -a $IGTOP/board/$IGconf_board/rootfs-overlay/ ${WORKROOT}/rootfs
fi


# post-build: hooks
if [ -x $IGTOP/board/$IGconf_board/post-build.sh ] ; then
   echo "$IGconf_board:post-build"
   $IGTOP/board/$IGconf_board/post-build.sh ${WORKROOT}/rootfs
fi


# pre-image: hooks - board has priority over image layout
if [ -x $IGTOP/board/$IGconf_board/pre-image.sh ] ; then
   echo "$IGconf_board:pre-image"
   $IGTOP/board/$IGconf_board/pre-image.sh ${WORKROOT}/rootfs ${WORKROOT}
elif [ -x $IGTOP/image/$IGconf_layout/pre-image.sh ] ; then
   echo "$IGconf_layout:pre-image"
   $IGTOP/image/$IGconf_layout/pre-image.sh ${WORKROOT}/rootfs ${WORKROOT}
else
   >&2 echo "no pre-image hook"
fi


# Must exist
if [ ! -s ${WORKROOT}/genimage.cfg ] ; then
   >&2 echo "genimage config was not created - image generation is not possible"; exit 1
fi

GTMP=$(mktemp -d)
trap 'rm -rf $GTMP' EXIT
mkdir -p $IGconf_deploydir

# Generate image
podman unshare genimage \
   --rootpath ${WORKROOT}/rootfs \
   --tmppath $GTMP \
   --inputpath ${WORKROOT}   \
   --outputpath ${WORKROOT} \
   --loglevel=10 \
   --config ${WORKROOT}/genimage.cfg
