#!/bin/bash
# 6-xgfbmove.sh -- builds XgFbMove.kext (the on-demand framebuffer mover that replaces FbRelocate.efi) from
# /Volumes/PKG/metal-stack/xgfbmove with the same kext command line as upstream's build_nmintelfb.sh, and adds it to
# /Volumes/PKG/metal-stack/out for install-metal.sh. Takes seconds; any OpenCore package will do.
#   bash /Volumes/PKG/metal-stack/6-xgfbmove.sh
. "$(dirname "$0")/common.sh"
S="$HERE/xgfbmove"
B="$OUTROOT/kexts/XgFbMove"
O="$HERE/out"
[ -f "$S/xgfbmove.cpp" ] && [ -f "$S/fbreloc_core.h" ] || { echo "missing sources in $S"; exit 1; }
[ -d "$O/kexts" ] || { echo "run 5-collect.sh first"; exit 1; }

build() {
  local K="$SDKROOT/System/Library/Frameworks/Kernel.framework/Headers"
  [ -d "$K" ] || { echo "no Kernel.framework headers in $SDKROOT"; return 1; }
  rm -rf "$B"; mkdir -p "$B/XgFbMove.kext/Contents/MacOS"
  xcrun clang++ -arch x86_64 -mmacosx-version-min=15.0 -fapple-kext -mkernel -nostdinc -isysroot "$SDKROOT" -I"$K" -I"$S" \
    -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
    -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common -O2 -Wall -Wno-unused-parameter -g0 \
    -Wno-deprecated-declarations -Wno-inconsistent-missing-override -Wno-overloaded-virtual -Wno-unused-function \
    -c "$S/xgfbmove.cpp" -o "$B/xgfbmove.o"
  xcrun clang++ -arch x86_64 -mmacosx-version-min=15.0 -fapple-kext -nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext \
    "$B/xgfbmove.o" -o "$B/XgFbMove.kext/Contents/MacOS/XgFbMove"
  cp "$S/Info.plist" "$B/XgFbMove.kext/Contents/Info.plist"
  plutil -lint "$B/XgFbMove.kext/Contents/Info.plist"
  codesign -s - -f "$B/XgFbMove.kext"
  nm "$B/XgFbMove.kext/Contents/MacOS/XgFbMove" | grep -E ' _kmod_info$| __start$| _start$'
  nm -u "$B/XgFbMove.kext/Contents/MacOS/XgFbMove"
}
collect() {
  rm -rf "$O/kexts/XgFbMove.kext"
  ditto --norsrc --noextattr "$B/XgFbMove.kext" "$O/kexts/XgFbMove.kext"
  (cd "$O" && find . -type f ! -name SHA256SUMS ! -name MANIFEST.txt ! -name '._*' | sort | xargs shasum -a 256 > SHA256SUMS)
  wc -l < "$O/SHA256SUMS" | xargs echo "files in out:"
}
step build-xgfbmove build
step collect-xgfbmove collect
cat "$LOGS/build-xgfbmove.log"
echo
echo "XgFbMove built. Next:  sudo bash /Volumes/PKG/metal-stack/install/install-metal.sh"
