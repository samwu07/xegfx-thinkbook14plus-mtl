#!/bin/bash
# renderfix-test.sh -- runs jxy333967's six offscreen tests (issue 2, pinned at jianxunyun@dfeaac89c81a) against the
# installed plugin and the candidate in out/GPUBundles. No sudo; each test loads the given plugin binary into its own
# process, draws into its own 32x32 offscreen texture and reads it back. WindowServer is left alone. Expected: the
# installed plugin fails the barrier tests (barrier-legacy: 512/1024 wrong), the candidate passes all six.
#   bash /Volumes/PKG/metal-stack/desktop/renderfix-test.sh
SRC=${RENDERFIX_SRC:-/Volumes/PKG/metal-stack/xeflip/renderfix-tests}
OLD=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver
NEW=/Volumes/PKG/metal-stack/out/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver
W=${TMPDIR:-/tmp}/renderfix.$$
[ -d "$SRC" ] || { echo "no test sources at $SRC (set RENDERFIX_SRC)"; exit 1; }
TESTS="barrier-legacy barrier-modern barrier-prebound barrier-repeat render-regression row-pitch-lifetime"
for t in $TESTS; do
  mkdir -p "$W/$t"   # the tests must be named nvmtltest, a name the plugin serves, so one folder each
  xcrun clang -arch x86_64 -fobjc-arc "$SRC/$t.m" -framework Foundation -framework Metal -framework IOKit -o "$W/$t/nvmtltest" || exit 1
done
for which in installed candidate; do
  P=$OLD; [ $which = candidate ] && P=$NEW
  echo "===== $which plugin"
  for t in $TESTS; do
    out=$(cd "$W/$t" && ./nvmtltest "$P" 2>&1 | tail -2 | tr '\n' ' '); rc=$?
    printf '%-20s %s\n' "$t" "$(echo "$out" | cut -c1-150)"
  done
done
rm -rf "$W"
