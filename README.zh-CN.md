# 联想 ThinkBook 14+ 2024 上的 XeGfx（Meteor Lake，Intel Arc 核显）

[English](README.md) | 简体中文

这里是一组脚本、补丁和笔记，把 [WTLIntelGfx / XeGfx](https://github.com/watchthelight-labs/WTLIntelGfx) v0.0.47
从“第 4 阶段拒绝运行、屏幕上出现一条色带”推进到了 **由 GPU 合成的 macOS 桌面**。机器是 ThinkBook 14+ 2024
（Core Ultra 7 155H，核显 `8086:7D55`，macOS Sequoia 15.8.1，OpenCore 1.0.8）。

仍属实验性质。测试时可能卡死或内核崩溃（panic），请保留另一个启动项和一个安全模式启动项作为退路。
源码树里不含 Apple 软件、上游二进制文件或固件：脚本会在 Mac 上按固定提交（`a3fd73ed`，标签 v0.0.47）拉取并编译上游代码。

## 遇到的问题与解决办法

| 问题 | 解决办法（位置） |
|---|---|
| GOP 帧缓冲位于 GGTT `0xFE800000`，越过了 `GUC_GGTT_TOP`：第 4 阶段拒绝运行（-28），或 GuC 镜像在屏幕上显示成一条色带（上游 issue #13） | `XgFbMove.kext` 在 XeGfx 加载前，从 macOS 中把帧缓冲的 GGTT 映射移到一段空闲区域（`0x80000000`），并在 vblank 时重新指向 `PLANE_SURF`；热重启后会回收残留旧条目的区域（`metal-stack/xgfbmove`，逻辑在 `fbreloc/fbreloc_core.h`，主机测试在 `fbreloc/test_fbreloc.py`） |
| 在登录密码界面卡死 | 按上游建议设置 `xegfx.nvram_trace=0` |
| WindowServer 在 Intel Metal 设备上反复崩溃 | CoreDisplay 预编译的 `default.metallib` 需要 AIR 位码读取器：把 MacPorts LLVM 20 的 `libLLVM.dylib` 重新链接后放进插件的 `air-runtime/`（`metal-stack/desktop/add-bitcode-reader.sh`） |
| 没有任何帧到达加速器（IOPresentment 关闭，上游 I-108） | GOP 帧缓冲位于 stolen memory，不在 GFX0 的两个 BAR 内，所以 GFX0 上的 IONDRVFramebuffer 始终没有上线，WindowServer 一直停在 UEFIGraphicsFB 的帧缓冲上。XeGfxIntelFB + `metal-stack/xeintelfb/bootvram.patch`：把控制台区域加为 GFX0 的设备内存，设置 `IOFBDependentID/Index`，并为 AGDC 提供屏幕 EDID 时序。另需 `debug.xegfx_agdc_k5=1` 和 `debug.nvaccel_iop=1`（`desktop-on.sh`） |
| 每一帧都由 CPU 拷贝（3072x1920 下 22.5 MiB） | XeGfxAccel 中实验性的 Intel 零拷贝翻页：WindowServer 的表面只在空闲 GGTT 区域映射一次，在 vblank 时翻转 `PLANE_SURF`（`metal-stack/xeflip`，`desktop/xeflip.sh try`）。实测：翻页 602 帧，拷贝 0 帧，失败 0 次 |
| 桌面被限制在约 30 帧/秒：WindowServer 以 30 Hz 的节拍合成 | XeGfxIntelFB 下面的启动 NDRV 没有 VBL 源。XeGfxIntelFB 0.9.4 注册了一个，由 pipe A 的帧计数器驱动（约 58 Hz；启动参数 `-xeintelfbnovbl` 可关闭）。另外，WindowServer 的完成标记改走加速器的 `XGDR` 连接，WindowServer 不再逐个等待合成完成（XeGfxAccel 0.9.4 及以后版本中的 `xeflip/wsmark.patch`，以及通过 `9-wsmark-plugin.sh` 应用的 `xeflip/wsmark-plugin.patch`；默认开启，`WSMARK=0` 关闭）。用 `desktop/fps-gaps` 测得：拖动窗口时约 58-60 帧/秒 |
| Wi-Fi 连接后 1-5 分钟反复出现内核崩溃 `Kernel trap at 0xffffffff....1130` | 与显卡无关：AirportItlwm 2.4.0（VedCloud 为 7E40 网卡制作的版本）的 `iwx_rm_sta_cmd` 在只有 9 项的表上遍历 16 个 TID，破坏了 `mac_ctxt_task`。在 `opencore/build_clean07.py` 中用一个两字节的 OpenCore `Kernel/Patch` 修复（`ITLWM_FIND` / `ITLWM_REPL`） |

桌面会在开机时自动启动（`desktop/autostart-boot.sh`，一个 LaunchDaemon；创建
`/Library/XeGfx/desktop/autostart-off` 即可暂停）。

已知问题：屏幕保持在固件设定的 60 Hz（XeGfx 从不切换显示模式）；应用需要在
`/Library/GPUBundles/nvmtl-allow.txt` 中有一行 `!App` 才能使用 Metal 设备；窗口背后的模糊效果（vibrancy）是透明的
（可用“减少透明度”规避）；部分小组件的圆角和材质（天气文字、青色色调）绘制不正确。

## 蓝牙

Intel CNVi 蓝牙（`8087:0033`，固件 `ibt-0180-0041`）需要以下三项同时满足（见 `bt/README.txt`）：
IntelBluetoothFirmware + IntelBTPatcher **2.5.0**（OpenIntelWireless master 分支的 Dortania 构建版；2.4.0 的 IntelBTPatcher
早于 Sequoia，蓝牙栈每约 16 秒重启一次）和 BlueToolFixup 2.7.2，放在 `Kernel/Add` 中 Lilu 之后
（`bt/add-bluetooth.sh apply`）；NVRAM 键 `bluetoothExternalDongleFailed` 和 `bluetoothInternalControllerInfo`
（`bt/bt-nvram.sh set`）；然后重启。非 Apple 的蓝牙控制器不支持隔空投送（AirDrop）、接力（Handoff）和连续互通（Continuity）。

## 二进制文件（Releases）

[Releases](https://github.com/samwu07/xegfx-thinkbook14plus-mtl/releases) 页面里有这台可正常工作的机器的备份：
实际启动用的 OpenCore EFI（序列号、MLB、ROM 和 SystemUUID 已替换为占位值，启动前请生成你自己的 SMBIOS），
以及已安装的 XeGfx 内核扩展和 Metal 插件。它们由 `release/collect-release.sh` 生成，
只适用于这款笔记本和 macOS 15.8.1。其中各部分的许可证见 `NOTICE`。

## 目录结构

- `xegfx/` - 逐个运行 XeGfx 的各阶段并生成报告（`run-xegfx-stages.sh`），以及安装/救援脚本
- `metal-stack/` - 在 Mac 上编译上游的加速器、AGDC、帧缓冲内核扩展、Metal 插件和 Mesa ANV（`0-` 到 `9-`），
  安装它们（`install/`），以及桌面路径（`desktop/`，完整经过见 `desktop/README.txt`）
- `fbreloc/` - XgFbMove 共用的帧缓冲重定位逻辑，附主机测试（Windows，clang + Python）
- `opencore/` - 这里使用的 OpenCore 打包脚本（源码树中不含配置和内核扩展，见 Releases）
- `bt/` - 在当前 EFI 上启用 Intel 蓝牙，以及它所需的 NVRAM 键
- `release/` - 收集 EFI（去除本机身份信息）和驱动，用于发布 Release

## 许可证

见 `NOTICE`（以英文为准）。简要来说：本仓库自己的脚本和代码采用 BSD-2-Clause；对 `kexts/XeGfxAccel` 的补丁
（`xeflip.patch`、`gpufb.patch`、`wsmark.patch`）和对 Metal 插件的补丁（`wsmark-plugin.patch`）修改的是
PolyForm Noncommercial 1.0.0 代码，沿用该许可证（禁止商业用途）；`bootvram.patch` 修改的是 BSD-2 的 XeGfxIntelFB 代码。
