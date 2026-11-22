#!/bin/bash
# clock-check.sh -- the real CPU clock under load: runs the multiply test (tools/ghz, one busy thread) while powermetrics
# samples the CPU's frequency, power and thermal pressure. About This Mac's "3 GHz" is only the SMBIOS label.
#   sudo bash /Volumes/PKG/cpuname/tools/clock-check.sh
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
D="$(cd "$(dirname "$0")" && pwd)"
"$D/ghz" > /tmp/ghz.$$ 2>&1 &
powermetrics --samplers cpu_power,thermal -i 3000 -n 4 2>&1 | grep -iE "frequency|nominal|pressure|package power|cpu power|throttl|HW active|P-State|C-State" | head -40
wait; echo "--- multiply test:"; cat /tmp/ghz.$$; rm -f /tmp/ghz.$$
