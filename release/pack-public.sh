#!/bin/bash
# pack-public.sh <stage-dir> -- the public Release zips from a stage that collect-release.sh made (identity already
# redacted there). Leaves out what may not be passed on: AMFIPass.kext (binary only, no licence) and the two ACPI tables
# made from Lenovo's firmware (DSDT-TB21LD-SCOPE.aml, APIC-TB21LD-BSP0.aml); their config.plist entries are disabled,
# and the MADT delete with them (no MADT at all otherwise). Adds LICENSES/, THIRD-PARTY.txt and, in the EFI zip,
# README-FIRST.txt. No sudo.
#   bash release/pack-public.sh /Volumes/PKG/release/stage-20261104-0140
# Output next to the stage: EFI-CLEAN-07Y-public-<date>.zip, xegfx-drivers-<date>.zip, SHA256-public-<date>.txt
set -euo pipefail
ST=$(cd "$1" && pwd); HERE="$(cd "$(dirname "$0")" && pwd)"; OUTD=$(dirname "$ST"); D=${ST##*stage-}
P="$OUTD/public-$D"; [ ! -e "$P" ] || { echo "$P exists: move it away first" >&2; exit 1; }
E="$P/EFI-CLEAN-07Y-public"; V="$P/xegfx-drivers"
mkdir -p "$E" "$V"
ditto --norsrc --noextattr "$ST/EFI" "$E/EFI"
rm -rf "$E/EFI/OC/Kexts/AMFIPass.kext" "$E/EFI/OC/ACPI/DSDT-TB21LD-SCOPE.aml" "$E/EFI/OC/ACPI/APIC-TB21LD-BSP0.aml"
python3 -I - "$E/EFI/OC/config.plist" <<'EOF'
import plistlib, sys
p = sys.argv[1]; c = plistlib.load(open(p, 'rb')); off = []
for e in c['Kernel']['Add']:
    if e['BundlePath'] == 'AMFIPass.kext': e['Enabled'] = False; off.append('Kernel/Add AMFIPass.kext')
for e in c['ACPI']['Add']:
    if e['Path'] in ('DSDT-TB21LD-SCOPE.aml', 'APIC-TB21LD-BSP0.aml'): e['Enabled'] = False; off.append('ACPI/Add ' + e['Path'])
for e in c['ACPI']['Delete']:
    if e.get('TableSignature') == b'APIC': e['Enabled'] = False; off.append('ACPI/Delete APIC')
g = c['PlatformInfo']['Generic']
assert g['SystemSerialNumber'].startswith('REDACTED') and g['MLB'].startswith('REDACTED'), 'identity not redacted'
assert g['SystemUUID'] == '00000000-0000-0000-0000-000000000000', 'UUID not redacted'
assert len(off) == 4, off
plistlib.dump(c, open(p, 'wb'), sort_keys=False)
print('disabled:', ', '.join(off))
EOF
plutil -lint "$E/EFI/OC/config.plist" > /dev/null
ditto --norsrc --noextattr "$ST/drivers" "$V"
for d in "$E" "$V"; do ditto "$HERE/LICENSES" "$d/LICENSES"; cp "$HERE/THIRD-PARTY.txt" "$d/"; done
cp "$HERE/README-FIRST.txt" "$E/"
find "$P" \( -name '.DS_Store' -o -name '._*' \) -delete
[ ! -e "$E/EFI/OC/Kexts/AMFIPass.kext" ] && [ -z "$(ls "$E"/EFI/OC/ACPI/ | grep -E 'DSDT|APIC' || true)" ] || { echo "left-out files still present" >&2; exit 1; }
[ ! -e "$V/Library-GPUBundles/nvmtl/air-opt" ] || { echo "air-opt present" >&2; exit 1; }
(cd "$P" && ditto -c -k --keepParent EFI-CLEAN-07Y-public "$OUTD/EFI-CLEAN-07Y-public-$D.zip" \
         && ditto -c -k --keepParent xegfx-drivers "$OUTD/xegfx-drivers-$D.zip")
(cd "$OUTD" && shasum -a 256 "EFI-CLEAN-07Y-public-$D.zip" "xegfx-drivers-$D.zip" > "SHA256-public-$D.txt" && cat "SHA256-public-$D.txt")
ls -l "$OUTD/EFI-CLEAN-07Y-public-$D.zip" "$OUTD/xegfx-drivers-$D.zip"
