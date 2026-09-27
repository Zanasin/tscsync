#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Remove everything install.sh added. Usage: sudo scripts/uninstall.sh
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -r /etc/tscsync.conf ] || { echo "tscsync is not installed" >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/tscsync.conf

if [ -e "$GRUB_DIR/custom.cfg" ]; then
	if grep -q '^# tscsync:' "$GRUB_DIR/custom.cfg"; then
		rm -f "$GRUB_DIR/custom.cfg"
	else
		echo "leaving $GRUB_DIR/custom.cfg alone: not created by tscsync" >&2
	fi
fi
"$EDITENV" "$GRUBENV" unset tscsync_enable tscsync_mode tscsync_pending
rm -rf "$ESP/EFI/tscsync"
systemctl disable tscsync-report.service 2>/dev/null || true
rm -f /etc/systemd/system/tscsync-report.service /usr/local/libexec/tscsync-report \
	/usr/local/bin/tscsync-status /etc/tscsync.conf
systemctl daemon-reload
echo "tscsync removed. The next boot is exactly as before installation."
