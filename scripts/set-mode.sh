#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Switch tscsync between measure (read-only), sync, and off.
# Usage: sudo scripts/set-mode.sh measure|sync|off [--any-cpu] [--exit-success]
#   --any-cpu       allow sync on CPUs outside the supported list (see README)
#   --exit-success  driver returns EFI_SUCCESS (for rEFInd; default is ABORTED
#                   for systemd-boot). Preserved across later set-mode calls
#                   unless you pass --no-exit-success.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -r /etc/tscsync.conf ] || { echo "tscsync is not installed (run scripts/install.sh)" >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/tscsync.conf

mode=
extra=
exit_tok=
clear_exit=
case "${1:-}" in
measure | sync | off) mode=$1 ;;
*) echo "usage: sudo $0 measure|sync|off [--any-cpu] [--exit-success|--no-exit-success]" >&2; exit 2 ;;
esac
shift
for arg in "$@"; do
	case "$arg" in
	--any-cpu) extra=" allow=any-cpu" ;;
	--exit-success) exit_tok=" exit=success"; clear_exit= ;;
	--no-exit-success) exit_tok=; clear_exit=1 ;;
	*) echo "usage: sudo $0 measure|sync|off [--any-cpu] [--exit-success|--no-exit-success]" >&2; exit 2 ;;
	esac
done

if [ "${LOADER:-grub}" = grub ]; then
	# Only the driver build (systemd-boot or rEFInd) reads exit=success; the
	# GRUB application always returns EFI_SUCCESS, so don't put it in grubenv.
	if [ -n "$exit_tok" ] || [ -n "$clear_exit" ]; then
		echo "note: --exit-success/--no-exit-success only apply to the driver (systemd-boot or rEFInd); ignored with GRUB" >&2
	fi
	exit_tok=
# Keep exit=success across mode changes unless cleared or newly requested.
elif [ -z "$exit_tok" ] && [ -z "$clear_exit" ] &&
   [ -r "$STATE_DIR/options" ] && grep -qw 'exit=success' "$STATE_DIR/options"; then
	exit_tok=" exit=success"
fi

if [ "${LOADER:-grub}" != grub ]; then
	# The driver reads these files on the ESP (see src/tscsync.c, sdboot_setup).
	rm -f "$STATE_DIR/pending"
	if [ "$mode" = off ]; then
		: >"$STATE_DIR/disabled"
	else
		printf 'mode=%s%s%s\n' "$mode" "$extra" "$exit_tok" >"$STATE_DIR/options"
		rm -f "$STATE_DIR/disabled"
	fi
	echo "options: $(cat "$STATE_DIR/options")$([ -e "$STATE_DIR/disabled" ] && echo '  (disabled)')"
else
	case "$mode" in
	measure) "$EDITENV" "$GRUBENV" set tscsync_enable=1 "tscsync_mode=mode=measure$extra" tscsync_pending=0 ;;
	sync)    "$EDITENV" "$GRUBENV" set tscsync_enable=1 "tscsync_mode=mode=sync$extra" tscsync_pending=0 ;;
	off)     "$EDITENV" "$GRUBENV" set tscsync_enable=0 tscsync_pending=0 ;;
	esac
	"$EDITENV" "$GRUBENV" list | grep '^tscsync'
fi
echo "Takes effect on the next boot."
