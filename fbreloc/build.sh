#!/bin/bash
# build.sh -- FbRelocate.efi (OpenCore UEFI driver) and the host test DLL, with LLVM from D:\LLVM.
set -euo pipefail
cd "$(dirname "$0")"
L=/d/LLVM/bin
mkdir -p out
CF=(-ffreestanding -fno-builtin -fno-stack-protector -mno-stack-arg-probe -fshort-wchar -O2 -Wall -Wextra -Werror)
"$L/clang" --target=x86_64-unknown-windows "${CF[@]}" -mno-red-zone -mgeneral-regs-only -c fbreloc.c -o out/fbreloc.obj
# -base:0: no preferred load address, so the firmware relocates it like any EDK2 driver (1.0 sat at 0x140000000)
"$L/lld-link" -nologo -subsystem:efi_boot_service_driver -entry:efi_main -nodefaultlib -base:0 -out:out/FbRelocate.efi out/fbreloc.obj
"$L/clang" --target=x86_64-pc-windows-msvc "${CF[@]}" -c fbr_test_dll.c -o out/fbr_test_dll.obj
"$L/lld-link" -nologo -dll -entry:_DllMainCRTStartup -nodefaultlib -out:out/fbr_test.dll out/fbr_test_dll.obj
ls -l out/FbRelocate.efi out/fbr_test.dll
