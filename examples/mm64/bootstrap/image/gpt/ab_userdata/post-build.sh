#!/bin/sh

set -eu

layout_top=$(readlink -f $(dirname "$0"))
rootfs="$1"

# post-build image layout specific ops can be added here
