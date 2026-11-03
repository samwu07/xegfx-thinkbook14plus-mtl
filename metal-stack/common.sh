# common.sh -- sourced by every metal-stack step: paths, pinned revisions, toolchain, job limit, logging.
# Layout and toolchain follow upstream WTLIntelGfx (README "Building", userland/BUILD.md): MacPorts LLVM 20 + meson,
# SPIRV-LLVM-Translator built into ~/.local/nvgfx-llvm. Homebrew is not used: it builds everything from source on
# Intel Macs since September 2026 (its LLVM compile was running when the Mac panicked on 2026-11-01).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$HERE/logs"; mkdir -p "$LOGS"
[ "$(id -u)" != 0 ] || { echo "run as your normal user, without sudo (the scripts ask for sudo themselves where needed)" >&2; exit 2; }
[ "$(uname -m)" = x86_64 ] || { echo "Intel Mac only" >&2; exit 2; }

SRC=$HOME/src
WTL=$SRC/WTLIntelGfx             # upstream repository
X=$SRC/xe-userland               # libdrm, Mesa (upstream userland layout)
DEPS=$SRC/deps                   # Vulkan-Headers, NVIDIA open-gpu-kernel-modules headers
OUTROOT=$SRC/XeGfx-build         # kexts/, plugin/, xlate/
OGKM_TAG=615.78.08
OGKM=$DEPS/open-gpu-$OGKM_TAG
MP=/opt/local                    # MacPorts
LLVM_CONFIG=$MP/libexec/llvm-20/bin/llvm-config
SPIRVLLVM=$HOME/.local/nvgfx-llvm  # SPIRV-LLVM-Translator for LLVM 20.1 (Mesa's mesa_clc needs LLVMSPIRVLib 20.1.x)

WTL_REV=a3fd73ed68ae82af7d3c6a80ec4336507e944ed7    # tag v0.0.47: the XeGfx.kext in OpenCore CLEAN-07F
DRM_REV=b97cbde15c5c3abfe44d78e8f57139e50f612fec    # userland/BUILD.md
MESA_REV=bffd91947efc1932da99aca69fc540d6d4201b0c   # userland/BUILD.md (26.3.0-devel)
VK_TAG=v1.4.328
SPIRVLLVM_TAG=v20.1.19
MACPORTS_PKG=https://github.com/macports/macports-base/releases/download/v2.12.7/MacPorts-2.12.7-15-Sequoia.pkg

# at most JOBS compilers at once (default 8 of the 155H's 22 threads); override with  JOBS=12 bash ...
JOBS=${JOBS:-8}
export MAKEFLAGS=-j$JOBS CMAKE_BUILD_PARALLEL_LEVEL=$JOBS CARGO_BUILD_JOBS=$JOBS

export PATH=$HOME/.venvs/mesa/bin:$HOME/.cargo/bin:$MP/bin:$MP/sbin:/usr/bin:/bin:/usr/sbin:/sbin
export CC=/usr/bin/clang CXX=/usr/bin/clang++ OBJC=/usr/bin/clang

# the macOS 15 SDK upstream pins (15.5), else the newest 15.x, else whatever xcrun picks
pick_sdk() {
  local d=/Library/Developer/CommandLineTools/SDKs s
  for s in "$d/MacOSX15.5.sdk" $(ls -d "$d"/MacOSX15.*.sdk 2>/dev/null | sort -r) "$d/MacOSX15.sdk"; do
    [ -d "$s/System/Library/Frameworks/Kernel.framework/Headers" ] && { echo "$s"; return; }
  done
  xcrun --sdk macosx --show-sdk-path 2>/dev/null || true
}
if xcode-select -p >/dev/null 2>&1; then export SDKROOT=$(pick_sdk); fi

# Build in OpenCore CLEAN-07A (no XeGfx, no FbRelocate). The 2026-11-01 22:27 build panic
# (vm_page_validate_no_references: page 0x140005000 is referenced) came in a CLEAN-07F boot with XeGfx idle; that
# physical page is FbRelocate.efi's preferred load address 0x140000000 + 0x5000, its .reloc page. Until that is
# understood, the builds refuse a boot where FbRelocate ran (its fbreloc-load variable exists) or XeGfx is loaded.
# ALLOW_FBRELOC=1 overrides the FbRelocate check.
no_xegfx() {
  if kmutil showloaded --list-only 2>/dev/null | grep -F "org.watchthelight.XeGfx (" > /dev/null; then   # no -q: SIGPIPE + pipefail
    echo "XeGfx is loaded in this boot (the stages ran). Restart into CLEAN-07A before building." >&2
    exit 3
  fi
  if [ -z "${ALLOW_FBRELOC:-}" ] && nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:fbreloc-load >/dev/null 2>&1; then
    echo "This boot ran FbRelocate.efi (OpenCore CLEAN-07F), the suspect in the 22:27 build panic." >&2
    echo "Build in CLEAN-07A: Windows -> work\\deploy-sn750-clean07a.bat, then boot MAC." >&2
    exit 3
  fi
}

# step <name> <command...>: all output to logs/<name>.log; stops the script on failure and shows the log's tail.
# The command runs in a subshell with its own errexit (an `if` around it would switch errexit off inside functions).
step() {
  local name=$1 rc t0=$SECONDS; shift
  printf '=== %-26s ' "$name"
  set +e
  ( set -eo pipefail; "$@" ) > "$LOGS/$name.log" 2>&1
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then printf 'ok (%ds)\n' $((SECONDS - t0)); return 0; fi
  printf 'FAILED (exit %d)\n--- last 30 lines of %s:\n' $rc "$LOGS/$name.log"
  tail -30 "$LOGS/$name.log"
  exit 1
}
