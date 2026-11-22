#!/bin/bash
# cpu-busy.sh -- what keeps CPUs awake: per-CPU interrupt rates and the busiest tasks over 10 s (powermetrics), while the
# Mac is otherwise idle. macOS CPU 0 and 13 are the boot P-core's two threads (APIC 32/33); 1-8 E-cores; 9-12 and 14-19
# P-core threads; 20-21 low-power E-cores.
#   sudo bash /Volumes/PKG/cpuname/tools/cpu-busy.sh
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
powermetrics --samplers interrupts,tasks -i 10000 -n 1 --show-process-wait-times 2>&1 \
  | grep -vE "^\s*$" | awk '/Interrupt distribution/{p=1} p' | head -70
