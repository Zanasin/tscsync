#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Idle benchmark for comparing clocksources (HPET vs TSC) under the same
# conditions. Read-only. Run with sudo to include CPU package power.
# Usage: [sudo] ./idle-bench.sh [seconds]   (default 300)
set -u
secs=${1:-300}
cs=/sys/devices/system/clocksource/clocksource0/current_clocksource
rapl=/sys/class/powercap/intel-rapl:0/energy_uj

tctl() { sensors 2>/dev/null | awk '/^Tctl:/ {gsub(/[+°C]/, "", $2); print $2; exit}'; }
idle_us() {	# total idle time of all CPUs, per state
	for f in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*/time; do
		echo "$(basename "$(dirname "$f")") $(cat "$f")"
	done | awk '{t[$1] += $2} END {for (s in t) print s, t[s]}' | sort
}

echo "clocksource: $(cat $cs)   boost: $(cat /sys/devices/system/cpu/cpufreq/boost)   profile: $(cat /sys/firmware/acpi/platform_profile)"
echo "AC online: $(cat /sys/class/power_supply/{ADP,AC}*/online 2>/dev/null | head -1)   duration: ${secs}s (keep the laptop idle)"

before=$(idle_us)
e0=$(cat $rapl 2>/dev/null)
t0=$(date +%s.%N)
sum=0 n=0 max=0
for ((i = 0; i < secs; i++)); do
	t=$(tctl)
	if [ -n "$t" ]; then
		sum=$(awk -v a="$sum" -v b="$t" 'BEGIN {print a + b}')
		max=$(awk -v a="$max" -v b="$t" 'BEGIN {print (b > a) ? b : a}')
		n=$((n + 1))
	fi
	sleep 1
done
t1=$(date +%s.%N)
e1=$(cat $rapl 2>/dev/null)
after=$(idle_us)
ncpu=$(nproc)

elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN {print b - a}')
echo "Tctl: avg $(awk -v s="$sum" -v n="$n" 'BEGIN {printf "%.1f", n ? s / n : 0}') °C, max ${max} °C over $n samples"
join <(echo "$before") <(echo "$after") | awk -v el="$elapsed" -v n="$ncpu" \
	'{p = 100 * ($3 - $2) / (el * 1e6 * n); idle += p; printf "%s: %.1f%%  ", $1, p} END {b = 100 - idle; printf "\nbusy: %.1f%% (counters and clock are read a few ms apart, so small values are approximate)\n", b < 0 ? 0 : b}'
if [ -n "$e0" ] && [ -n "$e1" ]; then
	range=$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj 2>/dev/null || echo 0)
	awk -v a="$e0" -v b="$e1" -v r="$range" -v el="$elapsed" 'BEGIN {d = b - a; if (d < 0) d += r; printf "CPU package power: %.2f W\n", d / 1e6 / el}'
else
	echo "CPU package power: run with sudo to include it"
fi
