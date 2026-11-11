#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Switch tscsync between measure (read-only), sync, and off.
# Usage: sudo scripts/set-mode.sh measure|sync|off [--any-cpu]
#          [--no-exit-success|--exit-success]
#          [--no-wide|--wide]
#          [--no-pause|--pause=key|--pause=N[s]]
#          [--color|--no-color]
#   --any-cpu         allow sync on CPUs outside the supported list (see README)
#   --exit-success    driver returns EFI_SUCCESS (for rEFInd; default is ABORTED
#                     for systemd-boot). Preserved across later set-mode calls
#                     unless you pass --no-exit-success.
#   --wide            pack compact per-AP cells across the console width
#   --pause=key       wait for a key before returning to the boot loader
#                     (driver only: with GRUB, powering off at the prompt
#                     would count as a hang and turn tscsync off)
#   --pause=N[s]      wait up to N seconds, 1-60 (optional trailing s); any
#                     key continues
#   --no-color        disable console colors (colors are on by default)
# Defaults are listed first in each optional group above; non-defaults are
# preserved across later set-mode calls until cleared.
set -euo pipefail

usage() {
	echo "usage: sudo $0 measure|sync|off [--any-cpu] [--no-exit-success|--exit-success] [--no-wide|--wide] [--no-pause|--pause=key|--pause=N[s]] [--color|--no-color]" >&2
	exit 2
}

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -r /etc/tscsync.conf ] || { echo "tscsync is not installed (run scripts/install.sh)" >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/tscsync.conf

mode=
extra=
exit_tok=
clear_exit=
wide_tok=
clear_wide=
pause_tok=
clear_pause=
color_tok=
clear_color=
case "${1:-}" in
measure | sync | off) mode=$1 ;;
*) usage ;;
esac
shift
for arg in "$@"; do
	case "$arg" in
	--any-cpu) extra=" allow=any-cpu" ;;
	--no-exit-success) exit_tok=; clear_exit=1 ;;
	--exit-success) exit_tok=" exit=success"; clear_exit= ;;
	--no-wide) wide_tok=; clear_wide=1 ;;
	--wide) wide_tok=" layout=wide"; clear_wide= ;;
	--no-pause) pause_tok=; clear_pause=1 ;;
	--pause=key) pause_tok=" pause=key"; clear_pause= ;;
	--pause=*)
		raw=${arg#--pause=}
		if [[ "$raw" =~ ^[1-9][0-9]?s?$ ]] && [ "${raw%s}" -le 60 ]; then
			# Normalize to pause=N (optional s accepted on input).
			pause_tok=" pause=${raw%s}"
			clear_pause=
		else
			usage
		fi
		;;
	--color) color_tok=; clear_color=1 ;;
	--no-color) color_tok=" color=off"; clear_color= ;;
	*) usage ;;
	esac
done

# Read previously stored display tokens from the options / grubenv line.
prev_line=
if [ "${LOADER:-grub}" != grub ]; then
	[ -r "$STATE_DIR/options" ] && prev_line=$(tr -d '\n' <"$STATE_DIR/options")
else
	env=$("$EDITENV" "$GRUBENV" list 2>/dev/null) || true
	if grep -qx 'tscsync_enable=1' <<<"$env"; then
		prev_line=$(sed -n 's/^tscsync_mode=//p' <<<"$env" | head -n1)
	fi
fi

if [ "${LOADER:-grub}" = grub ]; then
	# Only the driver build (systemd-boot or rEFInd) reads exit=success; the
	# GRUB application always returns EFI_SUCCESS, so don't put it in grubenv.
	if [ -n "$exit_tok" ] || [ -n "$clear_exit" ]; then
		echo "note: --exit-success/--no-exit-success only apply to the driver (systemd-boot or rEFInd); ignored with GRUB" >&2
	fi
	exit_tok=
	# GRUB marks the hang guard "returned" only after the tool returns, so a
	# power-off at a key prompt would look like a hang. A timed pause is fine.
	if [ "$pause_tok" = " pause=key" ]; then
		echo "--pause=key is not supported with GRUB (powering off at the prompt would turn tscsync off as a hang); use --pause=N, e.g. --pause=15" >&2
		exit 2
	fi
elif [ -z "$exit_tok" ] && [ -z "$clear_exit" ] &&
	grep -qw 'exit=success' <<<"$prev_line"; then
	exit_tok=" exit=success"
fi

# Preserve wide / pause / color=off unless cleared or newly set.
if [ -z "$wide_tok" ] && [ -z "$clear_wide" ] && grep -qw 'layout=wide' <<<"$prev_line"; then
	wide_tok=" layout=wide"
fi
if [ -z "$pause_tok" ] && [ -z "$clear_pause" ]; then
	if grep -qw 'pause=key' <<<"$prev_line"; then
		pause_tok=" pause=key"
	else
		prev_pause=$(grep -oE 'pause=[0-9]+s?' <<<"$prev_line" | head -n1 || true)
		if [ -n "$prev_pause" ]; then
			n=${prev_pause#pause=}
			n=${n%s}
			pause_tok=" pause=$n"
		fi
	fi
fi
if [ -z "$color_tok" ] && [ -z "$clear_color" ] && grep -qw 'color=off' <<<"$prev_line"; then
	color_tok=" color=off"
fi

opts_line="mode=${mode}${extra}${exit_tok}${wide_tok}${pause_tok}${color_tok}"

if [ "${LOADER:-grub}" != grub ]; then
	# The driver reads these files on the ESP (see src/tscsync.c, sdboot_setup).
	rm -f "$STATE_DIR/pending" "$STATE_DIR"/returned[123]
	if [ "$mode" = off ]; then
		: >"$STATE_DIR/disabled"
	else
		printf '%s\n' "$opts_line" >"$STATE_DIR/options"
		rm -f "$STATE_DIR/disabled"
	fi
	echo "options: $(cat "$STATE_DIR/options")$([ -e "$STATE_DIR/disabled" ] && echo '  (disabled)')"
else
	case "$mode" in
	measure | sync)
		"$EDITENV" "$GRUBENV" set tscsync_enable=1 "tscsync_mode=$opts_line" tscsync_pending=0
		;;
	off) "$EDITENV" "$GRUBENV" set tscsync_enable=0 tscsync_pending=0 ;;
	esac
	"$EDITENV" "$GRUBENV" list | grep '^tscsync'
fi
echo "Takes effect on the next boot."
