#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Write one CSV row per boot in the systemd journal: the kernel's TSC warp,
# systemd's firmware time and what tscsync did. Output goes to stdout.
#
# Usage: extract-boots.sh > data/boots.csv
#
# Columns:
#   journal_boot    journalctl boot offset (0 = the boot it was run on)
#   date            date of the boot
#   kernel          kernel version
#   warp_cycles     "Measured N cycles TSC warp between CPUs" (empty: no warp)
#   firmware_s      "Startup finished in Ns (firmware)"; systemd reads it
#                   from the ACPI FPDT (empty: not logged)
#   tscsync         tscsync version and mode (empty: not installed)
#   tsc_kept        1 if the kernel switched to (and kept) the TSC clocksource
#   offline_update  number of PackageKit offline-update log lines
set -euo pipefail

echo "journal_boot,date,kernel,warp_cycles,firmware_s,tscsync,tsc_kept,offline_update"
journalctl --list-boots --no-pager -q | while read -r idx _ _; do
	J=$(journalctl -b "$idx" --no-pager -q -o short-iso 2>/dev/null || true)
	date=$(grep -m1 'Startup finished in' <<<"$J" | awk '{print $1}' | cut -c1-10 || true)
	[ -n "$date" ] || date=$(tail -1 <<<"$J" | awk '{print $1}' | cut -c1-10)
	k=$(grep -m1 -o 'Linux version [0-9][0-9.]*-[0-9]*' <<<"$J" | awk '{print $3}' || true)
	w=$(grep -m1 -o 'Measured [0-9]* cycles TSC warp' <<<"$J" | awk '{print $2}' || true)
	fw=$(grep -m1 -o '[0-9.]*s (firmware)' <<<"$J" | cut -d's' -f1 || true)
	ts=$(grep -m1 -o 'tscsync [0-9.]*: mode=[a-z]*' <<<"$J" | sed 's/tscsync //; s/: mode=/ /' || true)
	cs=$(grep -c 'Switched to clocksource tsc$' <<<"$J" || true)
	upd=$(grep -c 'pk-offline-update' <<<"$J" || true)
	echo "$idx,$date,$k,$w,$fw,$ts,$cs,$upd"
done
