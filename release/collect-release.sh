#!/bin/bash
# collect-release.sh -- stage the live OpenCore EFI and the installed XeGfx drivers for a GitHub Release of
# samwu07/xegfx-thinkbook14plus-mtl, with the Mac's identity removed. Read-only on the EFI and on /Library.
#   sudo bash /Volumes/PKG/release/collect-release.sh
# Output: /Volumes/PKG/release/stage-<date>/{EFI,drivers} and two ZIPs next to it, owned by the invoking user.
# Redacted in the staged config.plist (PlatformInfo Generic/SMBIOS/DataHub/PlatformNVRAM): SystemSerialNumber, MLB,
# BoardSerialNumber, ChassisSerialNumber, SystemUUID, ROM. OpenCore debug logs (EFI/opencore-*.txt, SysReport) are left
# out. Then every staged file is searched for the real values; any hit stops the script (only counts are printed).
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
U=${SUDO_USER:-sam}; HERE="$(cd "$(dirname "$0")" && pwd)"; D=$(date +%Y%m%d-%H%M); S="$HERE/stage-$D"; DEV=/dev/disk0s1
PB=/usr/libexec/PlistBuddy
die() { echo "collect-release: $*" >&2; [ -n "${OWN:-}" ] && diskutil unmount "$MNT" > /dev/null 2>&1; exit 1; }
mkdir -p "$S/drivers"
MNT=$(diskutil info "$DEV" | sed -n 's/^ *Mount Point: *//p'); OWN=""
[ -n "$MNT" ] || { diskutil mount readOnly "$DEV" > /dev/null || die "cannot mount $DEV"; MNT=$(diskutil info "$DEV" | sed -n 's/^ *Mount Point: *//p'); OWN=1; }
[ -f "$MNT/EFI/OC/config.plist" ] || die "no EFI/OC/config.plist on $DEV"
ditto --norsrc --noextattr "$MNT/EFI" "$S/EFI"
[ -n "$OWN" ] && diskutil unmount "$MNT" > /dev/null 2>&1; OWN=""
find "$S/EFI" \( -name 'opencore-*.txt' -o -name 'SysReport' -o -name '._*' -o -name '.DS_Store' \) -prune -exec rm -rf {} + 2>/dev/null
# Apple's own EFI drivers are not redistributable either (OpenHfsPlus/OpenCore's are fine)
for f in "$S"/EFI/OC/Drivers/HfsPlus*.efi "$S"/EFI/OC/Drivers/ApfsDriverLoader*.efi; do [ -e "$f" ] && { echo "  left out Apple driver $(basename "$f")"; rm -f "$f"; }; done
C="$S/EFI/OC/config.plist"
# the real values, kept only in shell variables, to search for afterwards
SECRETS=()
for k in SystemSerialNumber MLB SystemUUID; do v=$($PB -c "Print :PlatformInfo:Generic:$k" "$C" 2>/dev/null) && [ -n "$v" ] && SECRETS+=("$v"); done
ROMHEX=$(plutil -extract PlatformInfo.Generic.ROM raw "$C" 2>/dev/null | base64 -D 2>/dev/null | xxd -p | tr -d '\n')
red() {   # $1 key path, $2 placeholder (string) -- only where the key exists
  $PB -c "Print :$1" "$C" > /dev/null 2>&1 || return 0
  if plutil -extract "$(echo "$1" | tr ':' '.')" raw -expect data "$C" > /dev/null 2>&1; then
    plutil -replace "$(echo "$1" | tr ':' '.')" -data "AAAAAAAA" "$C"
  else $PB -c "Set :$1 $2" "$C"; fi
  echo "  redacted $1"
}
for sec in Generic SMBIOS DataHub PlatformNVRAM; do
  red "PlatformInfo:$sec:SystemSerialNumber" "REDACTED-SERIAL"; red "PlatformInfo:$sec:ChassisSerialNumber" "REDACTED-SERIAL"
  red "PlatformInfo:$sec:BoardSerialNumber" "REDACTED-MLB";     red "PlatformInfo:$sec:MLB" "REDACTED-MLB"
  red "PlatformInfo:$sec:SystemUUID" "00000000-0000-0000-0000-000000000000"; red "PlatformInfo:$sec:ROM" "x"
done
plutil -lint "$C" > /dev/null || die "redacted config.plist does not validate"

# drivers as installed now
for k in XeGfxAccel XeGfxIntelFB XeGfxAGDC XgFbMove; do
  [ -d "/Library/Extensions/$k.kext" ] && ditto --norsrc --noextattr "/Library/Extensions/$k.kext" "$S/drivers/Library-Extensions/$k.kext"
done
mkdir -p "$S/drivers/Library-GPUBundles"
ditto --norsrc --noextattr /Library/GPUBundles/NVMTLDriver.bundle "$S/drivers/Library-GPUBundles/NVMTLDriver.bundle"
[ -d /Library/GPUBundles/nvmtl ] && ditto --norsrc --noextattr /Library/GPUBundles/nvmtl "$S/drivers/Library-GPUBundles/nvmtl"
rm -f "$S/drivers/Library-GPUBundles/nvmtl/air-opt"   # Apple's Metal toolchain (Apple LLVM): not ours to redistribute
cp -p /Library/GPUBundles/nvmtl-allow.txt "$S/drivers/Library-GPUBundles/" 2>/dev/null
mkdir -p "$S/drivers/autostart"; cp -p /Library/XeGfx/desktop/autostart-boot.sh /Library/LaunchDaemons/org.local.xegfx-desktop.plist "$S/drivers/autostart/" 2>/dev/null
find "$S" -name '*.prev' -delete

# nothing identifying may remain anywhere in the stage
hits=0
for v in "${SECRETS[@]}"; do n=$(grep -r -a -l -F -- "$v" "$S" 2>/dev/null | wc -l | tr -d ' '); hits=$((hits + n)); done
[ -n "$ROMHEX" ] && [ ${#ROMHEX} -ge 12 ] && { n=$(grep -r -a -l -F -- "$(echo "$ROMHEX" | xxd -r -p)" "$S" 2>/dev/null | wc -l | tr -d ' '); hits=$((hits + n)); }
echo "identity values checked: ${#SECRETS[@]} + ROM; files still containing one: $hits"
[ "$hits" = 0 ] || die "identity still present in $hits file(s): not packed"

(cd "$S" && ditto -c -k --keepParent EFI "$HERE/EFI-CLEAN-07Y-redacted-$D.zip" && ditto -c -k --keepParent drivers "$HERE/xegfx-drivers-$D.zip")
(cd "$HERE" && shasum -a 256 "EFI-CLEAN-07Y-redacted-$D.zip" "xegfx-drivers-$D.zip" > "SHA256-$D.txt")
chown -R "$U" "$S" "$HERE"/*-"$D".zip "$HERE/SHA256-$D.txt"
echo "EFI/OC/Drivers: $(ls "$S/EFI/OC/Drivers" | tr '\n' ' ')"; echo "EFI/OC/Kexts: $(ls "$S/EFI/OC/Kexts" | tr '\n' ' ')"
ls -la "$HERE"/*-"$D".zip; cat "$HERE/SHA256-$D.txt"; echo "stage: $S"
