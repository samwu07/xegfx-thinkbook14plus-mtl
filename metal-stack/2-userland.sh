#!/bin/bash
# 2-userland.sh -- libdrm and Mesa ANV for the Metal plugin, as upstream userland/BUILD.md + scripts/build_*.sh:
#   1. both NullMoth patches (Darwin) and both XeGfx patches (dma-buf/sync_file stand-ins, mapping by ioctl)
#   2. libdrm (core only, -Dintel=disabled), minimum macOS 11.0
#   3. host shader tools mesa_clc + vtn_bindgen2 (MacPorts LLVM 20 + ~/.local/nvgfx-llvm translator, build machine only)
#   4. Mesa ANV (-Dvulkan-drivers=intel, no LLVM in the target), minimum macOS 14.4 (futex API)
# Output: ~/src/xe-userland/prefix/lib/{libvulkan_intel.dylib,libdrm.2.dylib}
#   bash /Volumes/PKG/metal-stack/2-userland.sh
. "$(dirname "$0")/common.sh"
no_xegfx
[ -x "$LLVM_CONFIG" ] && [ -f "$SPIRVLLVM/lib/pkgconfig/LLVMSPIRVLib.pc" ] || { echo "run 0-prereqs.sh first"; exit 1; }
[ -d "$X/mesa/.git" ] || { echo "run 1-fetch.sh first"; exit 1; }
P=$WTL/userland/patches

patch_tree() {   # back to the pinned commit, then each patch with a dry run first
  local d=$1; shift
  git -C "$d" reset -q --hard HEAD
  git -C "$d" clean -qfdx
  for p in "$@"; do git -C "$d" apply --check "$p"; git -C "$d" apply "$p"; echo "applied $(basename "$p")"; done
  git -C "$d" status --short | wc -l | xargs echo "files changed:"
}
sdk_pc() {   # expat from the macOS SDK (BUILD.md: an empty libintel_decoder_gen.a breaks Apple ar otherwise)
  mkdir -p "$X/sdk-pc"
  printf 'Name: expat\nDescription: expat from the macOS SDK\nVersion: 2.7.1\nLibs: -lexpat\nCflags:\n' > "$X/sdk-pc/expat.pc"
}
libdrm() {
  export MACOSX_DEPLOYMENT_TARGET=11.0 PKG_CONFIG_LIBDIR=$X/prefix/lib/pkgconfig
  rm -rf "$X/drm/build"
  meson setup "$X/drm/build" "$X/drm" --prefix="$X/prefix" --libdir=lib -Dbuildtype=release \
    -Dc_args=-mmacosx-version-min=11.0 -Dc_link_args=-mmacosx-version-min=11.0 \
    -Dintel=disabled -Damdgpu=disabled -Dradeon=disabled -Dnouveau=disabled -Dvmwgfx=disabled -Domap=disabled \
    -Dexynos=disabled -Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled \
    -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dinstall-test-programs=false
  ninja -C "$X/drm/build" -j "$JOBS"
  meson install -C "$X/drm/build"
}
host_clc() {
  local LLVM_LIB; LLVM_LIB=$("$LLVM_CONFIG" --libdir)
  unset MACOSX_DEPLOYMENT_TARGET PKG_CONFIG_LIBDIR
  export PKG_CONFIG_PATH=$SPIRVLLVM/lib/pkgconfig
  printf "[binaries]\nllvm-config = '%s'\ncmake = 'false'\n" "$LLVM_CONFIG" > "$X/native-llvm.ini"
  rm -rf "$X/mesa/build-host"
  meson setup "$X/mesa/build-host" "$X/mesa" --native-file "$X/native-llvm.ini" --prefix="$X/host" -Dbuildtype=release \
    -Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dllvm=enabled -Dshared-llvm=enabled \
    -Dc_link_args=-Wl,-rpath,"$LLVM_LIB" -Dcpp_link_args=-Wl,-rpath,"$LLVM_LIB" \
    -Dvulkan-drivers= -Dgallium-drivers= -Dplatforms= -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
    -Degl=disabled -Dglx=disabled -Dglvnd=disabled -Dvulkan-layers= -Dtools= \
    -Dbuild-tests=false -Dexpat=disabled -Dzstd=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
    -Dvalgrind=disabled -Dxlib-lease=disabled -Dgallium-rusticl=false
  ninja -C "$X/mesa/build-host" -j "$JOBS"
  meson install -C "$X/mesa/build-host"
  "$X/host/bin/mesa_clc" --help > /dev/null
  ls -l "$X/host/bin"
}
mesa() {
  local MIN=14.4
  export MACOSX_DEPLOYMENT_TARGET=$MIN PATH=$X/host/bin:$PATH PKG_CONFIG_LIBDIR=$X/prefix/lib/pkgconfig:$X/sdk-pc
  unset PKG_CONFIG_PATH
  printf "[binaries]\ncmake = 'false'\nllvm-config = 'false'\n" > "$X/native-target.ini"
  rm -rf "$X/mesa/build"
  meson setup "$X/mesa/build" "$X/mesa" --native-file "$X/native-target.ini" --prefix="$X/prefix" --libdir=lib \
    -Dbuildtype=release -Db_ndebug=true \
    -Dc_args=-mmacosx-version-min=$MIN -Dcpp_args=-mmacosx-version-min=$MIN -Dobjc_args=-mmacosx-version-min=$MIN \
    -Dc_link_args=-mmacosx-version-min=$MIN -Dcpp_link_args=-mmacosx-version-min=$MIN \
    -Dvulkan-drivers=intel -Dgallium-drivers= -Dplatforms= -Dtools=drm-shim -Dllvm=disabled \
    -Dmesa-clc=system -Dprecomp-compiler=auto \
    -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Degl=disabled -Dglx=disabled -Dglvnd=disabled -Dgbm=disabled \
    -Dvulkan-layers= -Dbuild-tests=false -Dexpat=enabled -Dzstd=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
    -Dvalgrind=disabled -Dxlib-lease=disabled -Dgallium-rusticl=false -Dvideo-codecs=
  ninja -C "$X/mesa/build" -j "$JOBS"
  meson install -C "$X/mesa/build"
}
check() {
  local f
  for f in libvulkan_intel.dylib libdrm.2.dylib; do
    ls -l "$X/prefix/lib/$f"; otool -l "$X/prefix/lib/$f" | grep -A4 LC_BUILD_VERSION | grep -E 'minos|sdk'; otool -L "$X/prefix/lib/$f"
  done
  nm -gU "$X/prefix/lib/libvulkan_intel.dylib" | { grep -c vk_icd || true; } | xargs echo "vk_icd exports:"
  nm -gU "$X/prefix/lib/libdrm.2.dylib" | { grep -i -c nmx || true; } | xargs echo "libdrm NMX (XeGfx patch) exports:"
}
step patch-libdrm patch_tree "$X/drm" "$P/libdrm-macos.patch" "$P/libdrm-xegfx.patch"
step patch-mesa patch_tree "$X/mesa" "$P/mesa-macos.patch" "$P/mesa-xegfx.patch"
step sdk-pc sdk_pc
step build-libdrm libdrm
step build-host-clc host_clc
step build-mesa mesa
step check-userland check
cat "$LOGS/check-userland.log"
echo
echo "Userland done. Next:  bash /Volumes/PKG/metal-stack/3-plugin.sh"
