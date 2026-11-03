#!/bin/bash
# add-bitcode-reader.sh [--air-opt-only] -- gives the Metal plugin the AIR bitcode reader it was missing, then proves
# it on the exact shaders WindowServer crashed on, inside mtlprobe (a normal process: a failure here costs nothing).
#
# Why (2026-11-02, 14 WindowServer crashes): CoreDisplay loads Apple's precompiled default.metallib. The plugin turns
# its AIR bitcode into text with <bundle>/Contents/MacOS/air-runtime/libLLVM.dylib (in-process, LLVM C API) and, for
# every shader that one cannot read, with /Library/GPUBundles/nvmtl/air-opt (spawned as `air-opt -S in -o out`; the
# plugin looks for air-opt nowhere else). Neither existed -> "translation produced nothing" ->
# CoreDisplay::MetalDevice::GetGPUPassRenderPipelineState messaged nil (SIGSEGV at 0x18) -> crash loop -> watchdog panic.
#
#   1. air-runtime: MacPorts LLVM 20's libLLVM.dylib + every MacPorts library it needs, relinked to @loader_path so it
#      is self-contained -> into BOTH plugin bundles (system-wide for WindowServer, private for mtlprobe).
#      Skipped with --air-opt-only.
#   2. air-opt: VedCloud's copy (Apple LLVM 32023.917.2, macOS 14+) from /Volumes/PKG/gpu-7d55 if it is not there yet
#   3. if the accelerator is up (stage 7 ran): the plugin's own GPU-pass probe in mtlprobe, once per reader --
#      run A with only libLLVM, run B with only air-opt -- each with an empty translation cache (the plugin caches every
#      translation by content, so a second run would reuse the first one's results and prove nothing). All three
#      CoreDisplay pipelines (GPUPass, ColorFill, TextureCopy) must build.
#   4. the bundles are left as the passing run tested them, and /Library/XeGfx/desktop/gpupass-ok names the reader;
#      desktop-on.sh requires it before it ever restarts WindowServer.
#   sudo bash /Volumes/PKG/metal-stack/desktop/add-bitcode-reader.sh                  (run stages to 7 first)
#   sudo bash /Volumes/PKG/metal-stack/desktop/add-bitcode-reader.sh --air-opt-only   (air-opt alone, no libLLVM)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
die() { echo "add-bitcode-reader: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] || die "run with sudo from your user account"
ONLY_OPT=0; [ "${1:-}" = --air-opt-only ] && ONLY_OPT=1
LLVMLIB=/opt/local/libexec/llvm-20/lib
SYSB=/Library/GPUBundles/NVMTLDriver.bundle; PRIVB=/Library/XeGfx/metal/NVMTLDriver.bundle
PRT="$PRIVB/Contents/MacOS/air-runtime"
STAGE=/Library/XeGfx/air-runtime; AIROPT=/Library/GPUBundles/nvmtl/air-opt
VEDOPT=/Volumes/PKG/gpu-7d55/Library/GPUBundles/nvmtl/air-opt
FLAG=/Library/GPUBundles/nvmtl-gpupass-probe; GP=/Library/XeGfx/desktop/gpupass-ok
R="$HERE/reports/reader-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$R"
exec > >(tee "$R/add-bitcode-reader.log") 2>&1
[ -d "$SYSB" ] && [ -d "$PRIVB" ] || die "plugin bundles missing (install-metal.sh, install-desktop.sh)"
# an interrupted run (Ctrl-C, a panic) can leave a reader parked as *.off: put it back first
for p in "$AIROPT" "$PRT"; do
  if [ -e "$p.off" ]; then if [ -e "$p" ]; then rm -rf "$p.off"; else mv "$p.off" "$p"; fi; fi
done
rm -f "$FLAG"

resolve() {   # resolve <install name> -> a real path, or nothing for system libraries
  case "$1" in
    /opt/local/*) echo "$1" ;;
    @rpath/*) local b=${1#@rpath/}; for d in "$LLVMLIB" /opt/local/lib; do [ -f "$d/$b" ] && { echo "$d/$b"; return; }; done ;;
    @loader_path/*|@executable_path/*) echo "" ;;
  esac
}
pull() {      # pull <real path>: copy into the stage once, then its non-system dependencies, all relinked
  local src=$1 base; base=$(basename "$src")
  [ -f "$STAGE.new/$base" ] && return 0
  cp -L "$src" "$STAGE.new/$base" && chmod 755 "$STAGE.new/$base"
  install_name_tool -id "@loader_path/$base" "$STAGE.new/$base" 2>/dev/null
  local dep real
  for dep in $(otool -L "$src" | tail -n +2 | awk '{print $1}'); do
    real=$(resolve "$dep"); [ -n "$real" ] || continue
    [ "$(basename "$real")" = "$base" ] && continue
    install_name_tool -change "$dep" "@loader_path/$(basename "$real")" "$STAGE.new/$base" 2>/dev/null
    pull "$real" || return 1
  done
}
build_reader() {   # 0 = libLLVM with the plugin's C API is in both bundles
  [ -f "$LLVMLIB/libLLVM.dylib" ] || { echo "no $LLVMLIB/libLLVM.dylib (MacPorts llvm-20, 0-prereqs.sh)"; return 1; }
  rm -rf "$STAGE.new"; mkdir -p "$STAGE.new"
  pull "$LLVMLIB/libLLVM.dylib" || { echo "copying libLLVM and its libraries failed"; return 1; }
  local f s n left miss=""
  for f in "$STAGE.new"/*.dylib; do codesign -s - -f "$f" > /dev/null 2>&1 || echo "note: could not sign $(basename "$f")"; done
  echo "files: $(ls "$STAGE.new" | tr '\n' ' ')"
  left=$(for f in "$STAGE.new"/*.dylib; do otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/local|@rpath)'; done)
  [ -z "$left" ] || { echo "still points outside the folder: $left"; return 1; }
  # nm into a file, then grep the file. `nm | grep -q` under pipefail is what failed on 2026-11-02: grep -q stops at
  # the first match, nm dies of SIGPIPE writing the megabytes of C++ symbols after it, and pipefail turned that into
  # "libLLVM lacks LLVMContextCreate"
  nm -gU "$STAGE.new/libLLVM.dylib" > "$R/libLLVM-exports.txt" 2> "$R/libLLVM-nm-errors.txt"
  n=$(grep -c ' _LLVM' "$R/libLLVM-exports.txt")
  echo "libLLVM exports $n LLVM C API symbols ($(wc -l < "$R/libLLVM-exports.txt" | tr -d ' ') symbols in all)"
  if [ "$n" = 0 ]; then
    echo "note: nm listed none ($(head -1 "$R/libLLVM-nm-errors.txt")) -- installing anyway; run A decides"
  else
    # what the plugin dlsym()s before it calls the reader ready (NVMTLLibraryLoad.m, nvmtl_bitcode_reader_ready)
    for s in LLVMContextCreate LLVMContextDispose LLVMContextSetDiagnosticHandler \
             LLVMCreateMemoryBufferWithMemoryRangeCopy LLVMDisposeMemoryBuffer LLVMParseBitcodeInContext2 \
             LLVMPrintModuleToString LLVMDisposeModule LLVMDisposeMessage LLVMGetDiagInfoDescription; do
      grep -q " _$s\$" "$R/libLLVM-exports.txt" || miss="$miss $s"
    done
    [ -z "$miss" ] || { echo "libLLVM lacks what the plugin needs:$miss"; return 1; }
    grep -q ' _LLVMGetDiagInfoSeverity$' "$R/libLLVM-exports.txt" || echo "note: no LLVMGetDiagInfoSeverity (reader errors are only logged)"
  fi
  rm -rf "$STAGE"; mv "$STAGE.new" "$STAGE"
  [ -e "$PRT/air-opt" ] && echo "note: replacing $PRT, including the air-opt copy in it -- the plugin only ever runs $AIROPT"
  for bd in "$SYSB" "$PRIVB"; do
    rm -rf "$bd/Contents/MacOS/air-runtime"; ditto --norsrc --noextattr "$STAGE" "$bd/Contents/MacOS/air-runtime"
    chown -R root:wheel "$bd/Contents/MacOS/air-runtime"; chmod -R u=rwX,go=rX "$bd/Contents/MacOS/air-runtime"
  done
  du -sh "$STAGE" | awk '{print "air-runtime: " $1 " per bundle"}'
}

READER=0
if [ $ONLY_OPT = 1 ]; then echo "== 1. libLLVM skipped (--air-opt-only)"
else
  echo "== 1. self-contained air-runtime from MacPorts LLVM 20 -> $STAGE"
  if build_reader; then READER=1; else echo "-> no in-process reader this time; continuing with air-opt"; fi
fi

echo "== 2. air-opt ($AIROPT)"
if [ ! -x "$AIROPT" ] && [ -f "$VEDOPT" ]; then
  mkdir -p "$(dirname "$AIROPT")"
  cp "$VEDOPT" "$AIROPT.new" && xattr -c "$AIROPT.new" && chmod 755 "$AIROPT.new" && chown root:wheel "$AIROPT.new" \
    && mv -f "$AIROPT.new" "$AIROPT" && echo "installed from $VEDOPT"
fi
OPT=0
if [ -x "$AIROPT" ]; then
  # the plugin runs it as whoever uses Metal: it has to start for you, not just for root
  if sudo -u "$SUDO_USER" "$AIROPT" --version > "$R/air-opt-version.txt" 2>&1; then
    OPT=1; echo "starts: $(grep -m1 -i 'llvm version' "$R/air-opt-version.txt")"
  else echo "air-opt is there but does not start for $SUDO_USER (exit $?): $(head -3 "$R/air-opt-version.txt")"; fi
else echo "no air-opt here and none at $VEDOPT"; fi
[ $READER = 1 ] || [ $OPT = 1 ] || die "no bitcode reader at all: neither libLLVM nor air-opt. Send me $R."

echo "== 3. GPU-pass probe on CoreDisplay's shaders (inside mtlprobe)"
if ! ioreg -r -c NMXAccel -d 1 | grep NMXAccel > /dev/null; then
  echo "no NMXAccel in this boot: run  sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 7  and then this script again"
  exit 0
fi
UH=$(eval echo "~$SUDO_USER"); MP="$UH/src/XeGfx-build/mtlprobe/mtlprobe"
[ -x "$MP" ] || die "no $MP: run bash /Volumes/PKG/metal-stack/install/test-metal.sh once"
PARKED=()
park() { [ -e "$1" ] || return 0; mv "$1" "$1.off" && PARKED+=("$1"); }   # hide one reader from the plugin for a run
unpark() { local p; for p in ${PARKED[@]+"${PARKED[@]}"}; do [ -e "$p.off" ] && mv "$p.off" "$p"; done; PARKED=(); rm -f "$FLAG"; }
trap unpark EXIT
trap 'unpark; exit 130' INT TERM
probe() {     # probe <A|B>: one mtlprobe run, GPU-pass probe on, empty translation cache; 0 = all three pipelines built
  local log="$R/probe-$1.log" c rc
  c=$(mktemp -d /tmp/nvmtl-probe.XXXXXX); mkdir -p "$c/aircache"; chown -R "$SUDO_USER" "$c"
  touch "$FLAG"
  sudo -u "$SUDO_USER" env NVMTL_LOG_PATH="$c/nvmtl.log" NVMTL_AIRCACHE="$c/aircache" \
    NM_TEST_PLUGIN="$PRIVB/Contents/MacOS/NVMTLDriver" "$MP" > "$R/mtlprobe-$1.txt" 2>&1
  rc=$?
  rm -f "$FLAG"
  cp "$c/nvmtl.log" "$log" 2>/dev/null || : > "$log"
  echo "   mtlprobe exit $rc$([ $rc -gt 128 ] && echo " (killed by signal $((rc - 128)))"), $(ls "$c/aircache" | wc -l | tr -d ' ') shaders translated"
  ditto "$c/aircache" "$R/aircache-$1" 2>/dev/null; rm -rf "$c"
  grep -E "bitcode reader|air-opt|gpupass probe" "$log" | sed 's/^/   /' | head -14
  [ $rc -gt 128 ] || grep "gpupass probe:" "$log" > /dev/null || echo "   the probe did not run: see probe-$1.log and mtlprobe-$1.txt"
  [ "$(grep -c 'gpupass probe: .*PIPELINE BUILT' "$log")" -ge 3 ] \
    && ! grep -E 'gpupass probe: .*(FAILED|NO |no |cannot)|translation produced nothing' "$log" > /dev/null
}
A=skipped; B=skipped
if [ $READER = 1 ]; then
  echo "-- run A: libLLVM only (air-opt hidden)"
  park "$AIROPT"; if probe A; then A=PASS; else A=FAIL; fi; unpark
fi
if [ $OPT = 1 ]; then
  echo "-- run B: air-opt only (libLLVM hidden)"
  park "$PRT"; if probe B; then B=PASS; else B=FAIL; fi; unpark
fi
sync

echo
echo "run A, libLLVM only: $A      run B, air-opt only: $B"
mkdir -p "$(dirname "$GP")"
if [ $A = PASS ]; then
  printf 'reader=in-process\n%s: run A built GPUPass, ColorFill and TextureCopy; run B %s\n' "$(date)" "$B" > "$GP"
  echo "PASS: libLLVM in the plugin builds all three CoreDisplay pipelines$([ $OPT = 1 ] && echo '; air-opt stays as the fallback')."
  echo "desktop-on.sh may now restart WindowServer."
elif [ $B = PASS ]; then
  # leave the plugin as run B tested it: no in-process reader, every shader goes straight to air-opt
  OFF=/Library/XeGfx/air-runtime-unused-$(date +%Y%m%d-%H%M%S)
  for pair in "system:$SYSB" "private:$PRIVB"; do
    d="${pair#*:}/Contents/MacOS/air-runtime"
    [ -e "$d" ] && { mkdir -p "$OFF"; mv "$d" "$OFF/${pair%%:*}" && echo "moved aside: $d -> $OFF/${pair%%:*}"; }
  done
  printf 'reader=air-opt\n%s: run B built GPUPass, ColorFill and TextureCopy; run A %s\n' "$(date)" "$A" > "$GP"
  echo "PASS with air-opt: all three CoreDisplay pipelines build through $AIROPT."
  echo "desktop-on.sh may now restart WindowServer. Untested part: WindowServer has to start air-opt itself for every"
  echo "shader it has not seen yet; if it cannot, desktop-on's crash-loop guard switches it back to the software path."
else
  rm -f "$GP"
  echo "FAIL: CoreDisplay's shaders still do not build with either reader -- desktop-on.sh stays locked. Send me $R."
fi
echo "Reports: $R"
