#!/bin/bash
# 0-prereqs.sh -- toolchain, the way upstream built it (userland/BUILD.md):
#   MacPorts with prebuilt LLVM 20.1.8 + clang (binary archives only: nothing big is compiled here), meson, ninja,
#   glslang, cmake, python 3.14; a venv with mako/pyyaml/packaging for meson; SPIRV-LLVM-Translator v20.1.19 built
#   against MacPorts LLVM into ~/.local/nvgfx-llvm (the only C++ build here, ~10-20 min at JOBS=8); Rust.
# Asks for your password (sudo) for MacPorts. Homebrew is left alone and not used.
#   bash /Volumes/PKG/metal-stack/0-prereqs.sh
. "$(dirname "$0")/common.sh"
no_xegfx

xcode-select -p >/dev/null 2>&1 || { echo "Command Line Tools missing: run  xcode-select --install  , finish the dialog, then run this again."; exit 1; }
echo "SDK: $SDKROOT    jobs: $JOBS"
case "$SDKROOT" in */MacOSX15*) ;; *) echo "WARNING: no macOS 15 SDK found (upstream builds with 15.5); continuing with it" ;; esac

macports() {
  if [ -x "$MP/bin/port" ]; then "$MP/bin/port" version; return; fi
  local pkg=$HOME/Downloads/$(basename "$MACPORTS_PKG")
  curl -fL --retry 3 -o "$pkg" "$MACPORTS_PKG"
  pkgutil --check-signature "$pkg" | tee /dev/stderr | grep -q 'Developer ID Installer: The MacPorts Project' \
    || { echo "unexpected signature on $pkg"; return 1; }
  sudo installer -pkg "$pkg" -target /
  "$MP/bin/port" version
}
ports() {
  sudo "$MP/bin/port" -N selfupdate
  # -b: binary archives only; if LLVM had to be compiled this fails instead
  sudo "$MP/bin/port" -N -b install llvm-20 clang-20
  sudo "$MP/bin/port" -N install meson ninja glslang cmake pkgconfig bison flex python314
  "$LLVM_CONFIG" --version
}
venv() {
  [ -x "$HOME/.venvs/mesa/bin/python3" ] || "$MP/bin/python3.14" -m venv "$HOME/.venvs/mesa"
  "$HOME/.venvs/mesa/bin/pip" install --upgrade pip mako pyyaml packaging
}
spirv_llvm() {
  local s=$SRC/SPIRV-LLVM-Translator
  mkdir -p "$SRC"
  [ -d "$s/.git" ] || { git init -q "$s"; git -C "$s" remote add origin https://github.com/KhronosGroup/SPIRV-LLVM-Translator.git; }
  git -C "$s" fetch -q --depth 1 origin "refs/tags/$SPIRVLLVM_TAG"
  git -C "$s" checkout -q --force FETCH_HEAD
  rm -rf "$s/build"
  # SPIRV-Headers come from the commit pinned in the translator's spirv-headers-tag.conf (CMake fetches it)
  cmake -S "$s" -B "$s/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$SPIRVLLVM" \
    -DLLVM_DIR="$("$LLVM_CONFIG" --cmakedir)" -DLLVM_INCLUDE_TESTS=OFF -DCMAKE_OSX_SYSROOT="$SDKROOT" \
    -DCMAKE_IGNORE_PREFIX_PATH=/usr/local
  ninja -C "$s/build" -j "$JOBS"
  cmake --install "$s/build"
  PKG_CONFIG_PATH=$SPIRVLLVM/lib/pkgconfig pkg-config --modversion LLVMSPIRVLib
}
rust() {
  if [ -x "$HOME/.cargo/bin/rustup" ]; then "$HOME/.cargo/bin/rustup" update stable
  else curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable; fi
}
versions() {
  sw_vers; echo "CLT $(xcode-select -p)"; echo "SDK $SDKROOT"; echo "jobs $JOBS"
  /usr/bin/clang --version | head -1
  echo "llvm $("$LLVM_CONFIG" --version) at $("$LLVM_CONFIG" --prefix)"
  echo "LLVMSPIRVLib $(PKG_CONFIG_PATH=$SPIRVLLVM/lib/pkgconfig pkg-config --modversion LLVMSPIRVLib)"
  echo "meson $(meson --version)"; echo "ninja $(ninja --version)"; echo "cmake $(cmake --version | head -1)"
  glslangValidator --version | head -1; cargo --version; python3 --version
  python3 -c 'import mako, yaml, packaging; print("mako", mako.__version__)'
  df -h "$HOME" | tail -1
}

echo "MacPorts needs your password once:"
sudo -v
# keep sudo's 5-minute cache fresh while this script runs: with output going to the log, a second prompt would be
# invisible and look like a hang
( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null' EXIT
step macports macports
step macports-packages ports
step python-venv venv
step spirv-llvm-translator spirv_llvm
step rust rust
step versions versions
cat "$LOGS/versions.log"
echo
echo "Prerequisites done. Next:  bash /Volumes/PKG/metal-stack/1-fetch.sh"
