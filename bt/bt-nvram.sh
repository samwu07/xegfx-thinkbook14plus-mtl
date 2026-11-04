#!/bin/bash
# bt-nvram.sh set|unset|show -- the two NVRAM settings macOS 14+ wants for a non-Apple USB Bluetooth controller
# (OpenIntelWireless IntelBluetoothFirmware notes), then a bluetoothd restart so they are read without a reboot.
# 2026-11-04 01:07: with IntelBluetoothFirmware/IntelBTPatcher/BlueToolFixup loaded the controller ran its firmware
# (ibt-0180-0041, "Bluetooth USB Host Controller") but bluetoothd faulted every ~16 s and stayed "Address NULL".
#   sudo bash /Volumes/PKG/bt/bt-nvram.sh set
G=7C436110-AB2A-4BBB-A880-FE41995C9F82
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
case "${1:-show}" in
  set)   nvram "$G:bluetoothExternalDongleFailed=%00" && nvram "$G:bluetoothInternalControllerInfo=%00%00%00%00%00%00%00%00%00%00%00%00%00%00" \
           && echo "set; restarting bluetoothd" && pkill -x bluetoothd; sleep 8 ;;
  unset) nvram -d "$G:bluetoothExternalDongleFailed"; nvram -d "$G:bluetoothInternalControllerInfo"; pkill -x bluetoothd; echo "removed"; sleep 5 ;;
  show)  ;;
  *) echo "usage: $0 set|unset|show" >&2; exit 2 ;;
esac
nvram -p | grep -E 'bluetoothExternalDongleFailed|bluetoothInternalControllerInfo' || echo "(neither key set)"
system_profiler SPBluetoothDataType | grep -E 'Address|State|Chipset|Firmware|Transport' | head -6
