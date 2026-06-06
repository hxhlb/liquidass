#!/bin/zsh
set -euo pipefail
DEVICE_TARGET="iphone:clang:16.5:14.0"
MODE="${1:-}"
if [[ "$MODE" == "rootless" || -z "$MODE" ]]; then
    make clean
    make package ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
fi
if [[ "$MODE" == "rootful" || -z "$MODE" ]]; then
    make clean
    make package ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1
fi
# this only works if you got the roothide theos fork: https://github.com/roothide/theos
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
if [[ "$MODE" == "roothide" || -z "$MODE" ]]; then
    make clean
    make package ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
fi
