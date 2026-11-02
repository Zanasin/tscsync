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

# Keep exit=success across mode changes unless cleared or newly requested.
if [ -z "$exit_tok" ] && [ -z "$clear_exit" ] &&
   [ "${LOADER:-grub}" = systemd-boot ] &&
   [ -r "$STATE_DIR/options" ] && grep -qw 'exit=success' "$STATE_DIR/options"; then
	exit_tok=" exit=success"
fi

if [ "${LOADER:-grub}" = systemd-boot ]; then
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
	measure) "$EDITENV" "$GRUBENV" set tscsync_enable=1 "tscsync_mode=mode=measure$extra$exit_tok" tscsync_pending=0 ;;
	sync)    "$EDITENV" "$GRUBENV" set tscsync_enable=1 "tscsync_mode=mode=sync$extra$exit_tok" tscsync_pending=0 ;;
	off)     "$EDITENV" "$GRUBENV" set tscsync_enable=0 tscsync_pending=0 ;;
	esac
	"$EDITENV" "$GRUBENV" list | grep '^tscsync'
fi
echo "Takes effect on the next boot."
