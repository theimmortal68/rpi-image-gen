#!/bin/bash

IGTOP=$(readlink -f "$(dirname "$0")")
source "${IGTOP}/scripts/dependencies_check"
dependencies_install "${IGTOP}/depends"
