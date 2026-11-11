Bluetooth on the ThinkBook 14+ 155H (macOS 15.8.1, OpenCore CLEAN-07Y) -- WORKING since 2026-11-04 01:26.
Controller: Intel CNVi Bluetooth on USB, 8087:0033, firmware ibt-0180-0041 (Meteor Lake). System Information:
"Chipset THIRD_PARTY_DONGLE, Address xx:xx:xx:xx:xx:xx, State On". bluetoothd runs once and stays up.

What it takes (all three were needed):
  1. Kexts in EFI/OC/Kexts + Kernel/Add after Lilu (add-bluetooth.sh apply):
       IntelBluetoothFirmware 2.5.0 + IntelBTPatcher 2.5.0  -- Dortania build of OpenIntelWireless master a414375
         (downloads/ibf250). The 2.4.0 release (kexts-2.4.0) loads the firmware, but its IntelBTPatcher predates
         Sequoia: bluetoothd reached "Stack initialization complete", then LE_InitMultipleAdvertising failed (152) and
         "Reset scan ... STATUS 718" restarted the stack every ~16 s. Master's "compat for Sequoia" commits fix it.
       BlueToolFixup 2.7.2 (acidanthera BrcmPatchRAM, downloads/brcm)
  2. NVRAM 7C436110-AB2A-4BBB-A880-FE41995C9F82 (bt-nvram.sh set): bluetoothExternalDongleFailed = 00,
     bluetoothInternalControllerInfo = 14 x 00. Without them bluetoothd never found the USB controller
     ("Still cannot find USB Bluetooth Controller after 15 seconds"). Stored in the Mac's NVRAM, not in config.plist.
  3. A restart (OpenCore injects kexts only at boot).

A Windows deploy (work\deploy-sn750-clean07*.bat) replaces the EFI and drops the kexts: copy kexts/*.kext and the three
Kernel/Add entries into the work folder's EFI, or run  sudo bash /Volumes/PKG/bt/add-bluetooth.sh apply  again after it.
A full NVRAM reset (OpenCore "Reset NVRAM") drops the two keys: sudo bash /Volumes/PKG/bt/bt-nvram.sh set.
Undo: sudo bash /Volumes/PKG/bt/add-bluetooth.sh undo (config from the newest backup-*), bt-nvram.sh unset.
Continuity, tested 2026-11-07 with AirportItlwm 2.4.0 and an iPhone:
  Handoff and Universal Clipboard work from iPhone to Mac only, and only with iCloud Keychain on (without it the Handoff
  key exchange fails). Mac to iPhone does not work; at boot bluetoothd logs LE_InitMultipleAdvertising failed (STATUS 152),
  the likely cause. Not checked after sleep or restart.
  AirDrop from Mac to iPhone works without awdl0, with both on the same Wi-Fi: two files arrived and opened, over QUIC on
  en0 (transport localWiFi). The Mac UI still reported failure, and an earlier try failed with DNS Error: Refused, so it is
  not fully reliable. iPhone to Mac did not work in one test: the Mac's AirDrop server logs
  "Failed to initialize nw_interface, defaulting to loopback" and publishes _airdrop._tcp locally only. Re-advertising
  it on en0 with dns-sd did not help: the iPhone still did not list the Mac.
  iPhone Mirroring is not available: Apple requires Apple silicon or a T2 chip (not launched here).
  Apple Watch unlock: not tested.
