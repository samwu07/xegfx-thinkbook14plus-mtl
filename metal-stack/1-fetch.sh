#!/bin/bash
# 1-fetch.sh -- sources at pinned revisions into ~/src (APFS, never the exFAT PKG volume):
#   WTLIntelGfx v0.0.47, libdrm and Mesa at the commits upstream's userland/BUILD.md built, Vulkan-Headers v1.4.328,
#   NVIDIA open-gpu-kernel-modules 615.78.08 (headers the accelerator compiles against).
#   bash /Volumes/PKG/metal-stack/1-fetch.sh
. "$(dirname "$0")/common.sh"
mkdir -p "$SRC" "$X" "$DEPS"

at_rev() {   # at_rev <dir> <url> <commit or refs/tags/...>: shallow checkout of exactly that revision
  local d=$1 url=$2 rev=$3
  [ -d "$d/.git" ] || { git init -q "$d"; git -C "$d" remote add origin "$url"; }
  git -C "$d" fetch -q --depth 1 origin "$rev"
  git -C "$d" checkout -q --force FETCH_HEAD
  git -C "$d" log -1 --format='%H %cd %s'
}
ogkm() {
  if [ -d "$OGKM/src/nvidia/generated" ]; then echo "already unpacked: $OGKM"; return; fi
  local t="$DEPS/ogkm-$OGKM_TAG.tar.gz"
  curl -fL --retry 3 -o "$t" "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/$OGKM_TAG.tar.gz"
  rm -rf "$DEPS/open-gpu-kernel-modules-$OGKM_TAG" "$OGKM"
  tar -xzf "$t" -C "$DEPS"
  mv "$DEPS/open-gpu-kernel-modules-$OGKM_TAG" "$OGKM"
  rm -f "$t"
  [ -d "$OGKM/src/nvidia/generated" ] && echo "unpacked: $OGKM"
}
vkheaders() {
  at_rev "$X/Vulkan-Headers" https://github.com/KhronosGroup/Vulkan-Headers.git "refs/tags/$VK_TAG"
  ln -sfn "$X/Vulkan-Headers" "$DEPS/Vulkan-Headers"
}
step wtlintelgfx at_rev "$WTL" https://github.com/watchthelight-labs/WTLIntelGfx.git "$WTL_REV"
step libdrm at_rev "$X/drm" https://gitlab.freedesktop.org/mesa/libdrm.git "$DRM_REV"
step mesa at_rev "$X/mesa" https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_REV"
step vulkan-headers vkheaders
step nvidia-headers ogkm
for n in wtlintelgfx libdrm mesa vulkan-headers nvidia-headers; do printf '  %-15s %s\n' "$n" "$(tail -1 "$LOGS/$n.log")"; done
echo
echo "Sources ready. Next:  bash /Volumes/PKG/metal-stack/2-userland.sh   (20-40 minutes)"
