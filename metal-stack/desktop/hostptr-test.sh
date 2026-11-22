#!/bin/bash
# hostptr-test.sh -- runs hostptr-test against the Mesa before and after xemesa/hostptr-mesa.patch. No sudo; touches only
# its own process and leaves WindowServer alone.
#   bash /Volumes/PKG/metal-stack/desktop/hostptr-test.sh
H=/Volumes/PKG/metal-stack; T=${TMPDIR:-/tmp}/hostptr-test.$$
clang -I"$HOME/src/xe-userland/mesa/include" -o "$T" "$H/desktop/hostptr-test.c" || exit 1
echo "== old Mesa (expected: device lost)";              "$T" "$H/out/orig/libvulkan_intel.dylib"; echo "exit $?"
echo; echo "== new Mesa, wiring at import off (the stand-in path)"; XEGFX_ANV_NO_IMPORT_WIRE=1 "$T" "$H/out/GPUBundles/nvmtl/libvulkan_intel.dylib"; echo "exit $?"
echo; echo "== new Mesa as installed (wired at import)"; "$T" "$H/out/GPUBundles/nvmtl/libvulkan_intel.dylib"; echo "exit $?"
rm -f "$T"
