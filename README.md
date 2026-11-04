# XeGfx on the Lenovo ThinkBook 14+ 2024 (Meteor Lake, Intel Arc iGPU)

English | [简体中文](README.zh-CN.md)

Scripts, patches and notes that took [WTLIntelGfx / XeGfx](https://github.com/watchthelight-labs/WTLIntelGfx) v0.0.47
from "stage 4 refuses with a band on the panel" to a **GPU-composited macOS desktop** on a ThinkBook 14+ 2024
(Core Ultra 7 155H, iGPU `8086:7D55`, macOS Sequoia 15.8.1, OpenCore 1.0.8).

Experimental. Expect hangs and panics while testing; keep another boot entry and a Safe Mode entry as a way back.
No Apple software, no upstream binaries and no firmware are in the source tree: the scripts fetch and build upstream at a
pinned commit (`a3fd73ed`, tag v0.0.47) on the Mac.

## What was in the way, and what fixed it

| Problem | Fix (where) |
|---|---|
| GOP framebuffer at GGTT `0xFE800000` crosses `GUC_GGTT_TOP`: stage 4 refuses (-28) or the GuC image shows as a band (upstream issue #13) | `XgFbMove.kext` moves the framebuffer's GGTT mapping to a free range (`0x80000000`) from macOS before XeGfx loads, repointing `PLANE_SURF` at vblank; reclaims ranges holding stale entries after warm reboots (`metal-stack/xgfbmove`, logic in `fbreloc/fbreloc_core.h`, host tests in `fbreloc/test_fbreloc.py`) |
| Freeze at the login password | `xegfx.nvram_trace=0`, as upstream recommends |
| WindowServer crash loop on the Intel Metal device | CoreDisplay's precompiled `default.metallib` needs an AIR bitcode reader: MacPorts LLVM 20 `libLLVM.dylib`, relinked, in the plugin's `air-runtime/` (`metal-stack/desktop/add-bitcode-reader.sh`) |
| 0 frames reached the accelerator (IOPresentment off, upstream I-108) | The GOP framebuffer lives in stolen memory, outside both GFX0 BARs, so IONDRVFramebuffer on GFX0 never came online and WindowServer stayed on UEFIGraphicsFB's framebuffer. XeGfxIntelFB + `metal-stack/xeintelfb/bootvram.patch`: console range added as GFX0 device memory, `IOFBDependentID/Index`, the panel's EDID timing for AGDC. Plus `debug.xegfx_agdc_k5=1` and `debug.nvaccel_iop=1` (`desktop-on.sh`) |
| Every frame copied by the CPU (22.5 MiB at 3072x1920) | Experimental Intel zero-copy flip in XeGfxAccel: WindowServer's surfaces are mapped into free GGTT ranges once and `PLANE_SURF` is flipped at vblank (`metal-stack/xeflip`, `desktop/xeflip.sh try`). Measured: 602 frames flipped, 0 copied, 0 failures |
| Desktop capped at ~30 frames/s: WindowServer composited on a 30 Hz beat | The boot NDRV under XeGfxIntelFB had no VBL source. XeGfxIntelFB 0.9.4 registers one, driven by pipe A's frame counter (~58 Hz; boot-arg `-xeintelfbnovbl` turns it off). Plus WindowServer's completion marks on the accelerator's `XGDR` connection, so it stops waiting for each composite (`xeflip/wsmark.patch` in XeGfxAccel 0.9.4 and later, `xeflip/wsmark-plugin.patch` via `9-wsmark-plugin.sh`; on by default, `WSMARK=0` turns them off). Measured with `desktop/fps-gaps`: ~58-60 frames/s while dragging a window |
| Recurring kernel panic `Kernel trap at 0xffffffff....1130` 1-5 min after Wi-Fi connects | Not graphics: AirportItlwm 2.4.0 (VedCloud, for the 7E40 card) `iwx_rm_sta_cmd` walks 16 TIDs over a 9-entry table and corrupts `mac_ctxt_task`. Two-byte OpenCore `Kernel/Patch` in `opencore/build_clean07.py` (`ITLWM_FIND` / `ITLWM_REPL`) |

The desktop starts at boot (`desktop/autostart-boot.sh`, a LaunchDaemon; pause it with
`/Library/XeGfx/desktop/autostart-off`).

Known issues: the panel stays at the firmware's 60 Hz (XeGfx never mode-sets); apps need a `!App` line in
`/Library/GPUBundles/nvmtl-allow.txt` to get the Metal device; behind-window blur ("vibrancy") is see-through
(Reduce transparency works around it); some widget corners and materials (Weather text, cyan tints) draw wrong.

## Bluetooth

Intel CNVi Bluetooth (`8087:0033`, firmware `ibt-0180-0041`) works with three things together (`bt/README.txt`):
IntelBluetoothFirmware + IntelBTPatcher **2.5.0** (the Dortania build of OpenIntelWireless master; 2.4.0's IntelBTPatcher
predates Sequoia and the stack restarts every ~16 s) and BlueToolFixup 2.7.2 in `Kernel/Add` after Lilu
(`bt/add-bluetooth.sh apply`); the NVRAM keys `bluetoothExternalDongleFailed` and `bluetoothInternalControllerInfo`
(`bt/bt-nvram.sh set`); a restart. AirDrop, Handoff and Continuity do not work with a non-Apple controller.

## Binaries (Releases)

The [Releases](https://github.com/samwu07/xegfx-thinkbook14plus-mtl/releases) page has a backup of the working machine:
the OpenCore EFI as booted, with the serial number, MLB, ROM and SystemUUID replaced by placeholders (generate your own
SMBIOS before you boot it), and the installed XeGfx kexts and Metal plugin. `release/collect-release.sh` makes them.
They fit this exact laptop and macOS 15.8.1 only. Licences of what is inside: `NOTICE`.

## Layout

- `xegfx/` - running XeGfx's stages one at a time with reports (`run-xegfx-stages.sh`), install/rescue scripts
- `metal-stack/` - building upstream's accelerator, AGDC, framebuffer kexts, Metal plugin and Mesa ANV on the Mac
  (`0-` to `9-`), installing them (`install/`), and the desktop path (`desktop/`, see `desktop/README.txt` for the
  full history)
- `fbreloc/` - the framebuffer relocation logic shared by XgFbMove, with host tests (Windows, clang + Python)
- `opencore/` - the OpenCore package builder used here (configs and kexts are not in the source tree; see Releases)
- `bt/` - Intel Bluetooth on the live EFI and the NVRAM keys it needs
- `release/` - collecting the EFI (with the Mac's identity removed) and the drivers for a Release

## Licences

See `NOTICE`. In short: own scripts and code are BSD-2-Clause; the patches to `kexts/XeGfxAccel` (`xeflip.patch`,
`gpufb.patch`, `wsmark.patch`) and to the Metal plugin (`wsmark-plugin.patch`) modify PolyForm Noncommercial 1.0.0 code and stay under that licence (no commercial use);
`bootvram.patch` modifies BSD-2 XeGfxIntelFB code.
