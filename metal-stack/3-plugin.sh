#!/bin/bash
# 3-plugin.sh -- the Metal side in userspace, with upstream's own scripts:
#   build/build_plugin.sh  -> NVMTLDriver (Metal API on Vulkan/ANV), wrapped here into NVMTLDriver.bundle, the name the
#                             accelerator's MetalPluginName points at (/Library/GPUBundles/NVMTLDriver.bundle)
#   build/build_xlate.sh   -> libnvmtl_translate.dylib (Metal AIR -> SPIR-V, Rust)
# Diagnostics stay compiled in (no RELEASE=1): the plugin logs to /tmp/nvmtl.log, which is what we will need.
#   bash /Volumes/PKG/metal-stack/3-plugin.sh
. "$(dirname "$0")/common.sh"
no_xegfx
[ -f "$WTL/build/build_plugin.sh" ] || { echo "run 1-fetch.sh first"; exit 1; }
[ -x "$HOME/.cargo/bin/cargo" ] || { echo "run 0-prereqs.sh first (Rust)"; exit 1; }

plugin() { XEGFX_DEPS="$DEPS" XEGFX_OUT="$OUTROOT" bash "$WTL/build/build_plugin.sh"; }
xlate() {
  # upstream compares exports with NullMoth's shipped 2.1.0 dylib, which we do not have; pointing the reference at the
  # output folder turns that comparison into a no-op instead of a failed find
  mkdir -p "$OUTROOT/xlate"
  NVGFX_REF_PKGROOT="$OUTROOT/xlate" XEGFX_OUT="$OUTROOT" bash "$WTL/build/build_xlate.sh"
}
bundle() {
  local B=$OUTROOT/plugin/NVMTLDriver.bundle
  rm -rf "$B"; mkdir -p "$B/Contents/MacOS"
  cp "$OUTROOT/plugin/NVMTLDriver" "$B/Contents/MacOS/NVMTLDriver"
  cat > "$B/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>NVMTLDriver</string>
	<key>CFBundleIdentifier</key>
	<string>com.nullmoth.NVMTLDriver</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>NVMTLDriver</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>0.1</string>
</dict>
</plist>
EOF
  plutil -lint "$B/Contents/Info.plist"
  codesign -s - -f "$B"
  file "$B/Contents/MacOS/NVMTLDriver"
  nm -gU "$B/Contents/MacOS/NVMTLDriver" | { grep -c 'OBJC_CLASS_\$_NVMTLDevice' || true; } | xargs echo "NVMTLDevice class:"
}
step build-plugin plugin
step build-translator xlate
step plugin-bundle bundle
tail -2 "$LOGS/build-plugin.log"; tail -2 "$LOGS/build-translator.log"; cat "$LOGS/plugin-bundle.log"
echo
echo "Plugin done. Next:  bash /Volumes/PKG/metal-stack/4-kexts.sh"
