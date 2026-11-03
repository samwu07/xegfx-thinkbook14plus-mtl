#!/bin/bash
# update-xgfbmove.sh -- replaces only XgFbMove.kext (built by 6-xgfbmove.sh); the work is update-kext.sh's.
#   sudo bash /Volumes/PKG/metal-stack/install/update-xgfbmove.sh        then restart into CLEAN-07Y
exec bash "$(cd "$(dirname "$0")" && pwd)/update-kext.sh" XgFbMove "$@"
