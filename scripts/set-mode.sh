#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Switch tscsync between measure (read-only), sync, and off.
# Usage: sudo scripts/set-mode.sh measure|sync|off [--any-cpu]
#   --any-cpu  allow sync on CPUs outside the supported list (see README)
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -r /etc/tscsync.conf ] || { echo "tscsync is not installed (run scripts/install.sh)" >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/tscsync.conf

extra=
[ "${2:-}" = --any-cpu ] && extra=" allow=any-cpu"
case "${1:-}" in
measure | sync | off) ;;
*) echo "usage: sudo $0 measure|sync|off [--any-cpu]" >&2; exit 2 ;;
esac

if [ "${LOADER:-grub}" = systemd-boot ]; then
	# The driver reads these files on the ESP (see src/tscsync.c, sdboot_setup).
	rm -f "$STATE_DIR/pending"
	if [ "$1" = off ]; then
		: >"$STATE_DIR/disabled"
	else
		printf 'mode=%s%s\n' "$1" "$extra" >"$STATE_DIR/options"
		rm -f "$STATE_DIR/disabled"
	fi
	echo "options: $(cat "$STATE_DIR/options")$([ -e "$STATE_DIR/disabled" ] && echo '  (disabled)')"
else
	case "$1" in
	measure) "$EDITENV" "$GRUBENV" set tscsync_enable=1 "tscsync_mode=mode=measure$extra" tscsync_pending=0 ;;
	sync)    "$EDITENV" "$GRUBENV" set tscsync_enable=1 "tscsync_mode=mode=sync$extra" tscsync_pending=0 ;;
	off)     "$EDITENV" "$GRUBENV" set tscsync_enable=0 tscsync_pending=0 ;;
	esac
	"$EDITENV" "$GRUBENV" list | grep '^tscsync'
fi
echo "Takes effect on the next boot."
