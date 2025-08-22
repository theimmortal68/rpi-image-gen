#!/bin/bash

set -eu

KS_TOP=$(readlink -f "$(dirname "$0")")
source "${KS_TOP}/scripts/dependencies_check"
depf=("${KS_TOP}/depends")
for f in "$@" ; do
   depf+=($(realpath -e "$f"))
done
dependencies_install "${depf[@]}"
