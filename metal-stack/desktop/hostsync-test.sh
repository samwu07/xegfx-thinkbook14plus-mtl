#!/bin/bash
# hostsync-test.sh -- runs hostsync-test against the installed plugin. No sudo; its own process only, WindowServer is left
# alone. "survived" = fixed; a segmentation fault = the 22:49 crash. Builds the tool under the name nvmtlrender, a name
# the plugin serves.
#   bash /Volumes/PKG/metal-stack/desktop/hostsync-test.sh
H=/Volumes/PKG/metal-stack/desktop; T=${TMPDIR:-/tmp}/hs$$; mkdir -p "$T"
clang -fobjc-arc -framework Metal -framework Foundation -o "$T/nvmtlrender" "$H/hostsync-test.m" || exit 1
rc=0
for m in gone readonly; do echo "== $m"; NVMTL_ENABLE=1 "$T/nvmtlrender" $m; r=$?; echo "exit $r"; [ $r = 0 ] || rc=$r; done
rm -rf "$T"; exit $rc
