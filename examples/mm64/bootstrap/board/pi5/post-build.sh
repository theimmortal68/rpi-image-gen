#!/bin/sh

set -eu

board_top=$(readlink -f $(dirname "$0"))
rootfs=$1

# post-build pi5 board specific ops can be added here
