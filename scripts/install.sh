#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Install tscsync in MEASURE mode (read-only: it writes nothing to the CPU).
#
# Usage: sudo scripts/install.sh [options]
#   --key FILE --cert FILE   Secure Boot signing key and certificate (PEM key,
#                            PEM or DER cert) enrolled as a MOK or in db
#   --no-sign                install unsigned (only if Secure Boot is off, or
#                            you sign the .efi yourself, e.g. with sbctl)
#   --loader grub|systemd-boot
#                            boot loader to hook into (default: detected)
#   --esp DIR                EFI system partition mount point
#   --grub-dir DIR           GRUB config directory (holding grub.cfg)
#
# What it changes, all reversible with scripts/uninstall.sh:
#   GRUB:          <ESP>/EFI/tscsync/tscsync.efi
#                  <grub-dir>/custom.cfg           sourced by grub.cfg (41_custom)
#                  grubenv: tscsync_enable=1 tscsync_mode=mode=measure tscsync_pending=0
#   systemd-boot:  <ESP>/EFI/systemd/drivers/tscsyncx64.efi
#                  <ESP>/EFI/tscsync/options       "mode=measure"
#   both:          /usr/local/libexec/tscsync-report     clears the hang guard after boot
#                  /usr/local/bin/tscsync-status         status command
#                  /etc/systemd/system/tscsync-report.service
#                  /etc/tscsync.conf                     paths detected here
# It does not modify grub.cfg, loader.conf, boot entries, the kernel command
# line, or firmware settings.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "install.sh: $*" >&2; exit 1; }
note() { echo "== $*"; }

KEY= CERT= NOSIGN=0 ESP= GRUB_DIR= LOADER= CUSTOM=
while [ $# -gt 0 ]; do
	case "$1" in
	--key) KEY=$2; shift 2 ;;
	--cert) CERT=$2; shift 2 ;;
	--no-sign) NOSIGN=1; shift ;;
	--loader) LOADER=$2; shift 2 ;;
	--esp) ESP=$2; shift 2 ;;
	--grub-dir) GRUB_DIR=$2; shift 2 ;;
	-h | --help) sed -n '3,26p' "$0"; exit 0 ;;
	*) die "unknown option $1 (see --help)" ;;
	esac
done

[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(uname -m)" = x86_64 ] || die "only x86_64 is supported"
[ -d /sys/firmware/efi ] || die "not booted in UEFI mode"
command -v systemctl >/dev/null || die "systemd is required (it clears the hang guard after boot)"
if [ -e /etc/tscsync.conf ]; then
	# shellcheck source=/dev/null
	OLD_LOADER=$(. /etc/tscsync.conf; echo "${LOADER:-grub}")
fi

# --- boot loader -------------------------------------------------------------
# systemd-boot records itself in the LoaderInfo EFI variable on every boot.
LOADER_INFO=/sys/firmware/efi/efivars/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
if [ -z "$LOADER" ]; then
	if [ -r "$LOADER_INFO" ] && tr -d '\000' <"$LOADER_INFO" | grep -q 'systemd-boot'; then
		LOADER=systemd-boot
	elif [ -f /boot/grub2/grub.cfg ] || [ -f /boot/grub/grub.cfg ] || [ -n "$GRUB_DIR" ]; then
		LOADER=grub
	else
		die "cannot tell which boot loader is in use; pass --loader grub or --loader systemd-boot"
	fi
fi
case "$LOADER" in
grub | systemd-boot) ;;
*) die "--loader must be grub or systemd-boot" ;;
esac
[ -n "${OLD_LOADER:-}" ] && [ "$OLD_LOADER" != "$LOADER" ] &&
	die "tscsync is installed for $OLD_LOADER; run scripts/uninstall.sh first"
note "boot loader: $LOADER"

EFI_BIN=build/tscsync.efi
[ "$LOADER" = systemd-boot ] && EFI_BIN=build/tscsync-driver.efi
[ -f "$EFI_BIN" ] || die "$EFI_BIN not built (run: make)"
if strings -el "$EFI_BIN" | grep -q 'TEST BUILD'; then
	die "$EFI_BIN is the VM test build; rebuild with: make clean all"
fi

# --- EFI system partition --------------------------------------------------
if [ -z "$ESP" ] && [ "$LOADER" = systemd-boot ] && command -v bootctl >/dev/null; then
	ESP=$(bootctl --print-esp-path 2>/dev/null || true)
fi
if [ -z "$ESP" ]; then
	for d in /boot/efi /efi /boot; do
		if [ "$(findmnt -no FSTYPE -T "$d" 2>/dev/null)" = vfat ] && [ -d "$d/EFI" ]; then
			ESP=$d
			break
		fi
	done
fi
[ -n "$ESP" ] && [ -d "$ESP/EFI" ] || die "no EFI system partition found (use --esp)"
ESP_UUID=$(findmnt -no UUID -T "$ESP")
[ -n "$ESP_UUID" ] || die "cannot read the UUID of $ESP"

# --- GRUB ------------------------------------------------------------------
if [ "$LOADER" = grub ]; then
	if [ -z "$GRUB_DIR" ]; then
		for d in /boot/grub2 /boot/grub; do
			[ -f "$d/grub.cfg" ] && { GRUB_DIR=$d; break; }
		done
	fi
	[ -n "$GRUB_DIR" ] && [ -f "$GRUB_DIR/grub.cfg" ] ||
		die "no GRUB config found (use --grub-dir if it is elsewhere)"
	grep -q 'custom.cfg' "$GRUB_DIR/grub.cfg" ||
		die "$GRUB_DIR/grub.cfg does not source custom.cfg (GRUB's 41_custom script is missing)"
	CUSTOM=$GRUB_DIR/custom.cfg
	if [ -e "$CUSTOM" ] && ! grep -q '^# tscsync:' "$CUSTOM"; then
		die "$CUSTOM already exists and was not created by tscsync; not touching it"
	fi
	EDITENV=$(command -v grub2-editenv || command -v grub-editenv || true)
	[ -n "$EDITENV" ] || die "grub-editenv / grub2-editenv not found"
	GRUBENV=$GRUB_DIR/grubenv
	# GRUB can only rewrite grubenv on simple filesystems; the hang guard needs it.
	GRUB_FS=$(findmnt -no FSTYPE -T "$GRUB_DIR")
	case "$GRUB_FS" in
	ext2 | ext3 | ext4 | vfat) ;;
	*) die "$GRUB_DIR is on $GRUB_FS; GRUB can only save its hang guard on ext2/3/4 or FAT" ;;
	esac
	case "$(findmnt -no SOURCE -T "$GRUB_DIR")" in
	/dev/mapper/* | /dev/md*) die "$GRUB_DIR is on LVM, LUKS or RAID; GRUB cannot save its hang guard there" ;;
	esac
fi

# --- systemd-boot ----------------------------------------------------------
if [ "$LOADER" = systemd-boot ]; then
	[ -d "$ESP/EFI/systemd" ] || die "$ESP/EFI/systemd not found: is systemd-boot installed on $ESP?"
	STATE_DIR=$ESP/EFI/tscsync
	DRIVER=$ESP/EFI/systemd/drivers/tscsyncx64.efi
	if [ -e "$DRIVER" ] && [ ! -e "$STATE_DIR/options" ]; then
		die "$DRIVER already exists and was not installed by tscsync; not touching it"
	fi
fi

# --- Secure Boot signing ---------------------------------------------------
SB=0
if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
	SB=1
elif [ -r /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c ] &&
	[ "$(od -An -tu1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c | tr -d ' ')" = 1 ]; then
	SB=1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$EFI_BIN" "$tmp/tscsync.efi"

if [ "$NOSIGN" = 1 ]; then
	[ "$SB" = 1 ] && echo "WARNING: Secure Boot is on and --no-sign was given; the boot loader will refuse the tool unless you sign it yourself."
else
	if [ -z "$KEY" ]; then
		# Keys that distributions already use for out-of-tree kernel modules
		# (MOKs), and sbctl's db key. systemd-boot's drivers are checked
		# against db, so there sbctl's key comes first.
		MOKS="/etc/pki/akmods/private/private_key.priv:/etc/pki/akmods/certs/public_key.der
			/var/lib/dkms/mok.key:/var/lib/dkms/mok.pub
			/var/lib/shim-signed/mok/MOK.priv:/var/lib/shim-signed/mok/MOK.der"
		DBKEYS="/var/lib/sbctl/keys/db/db.key:/var/lib/sbctl/keys/db/db.pem
			/usr/share/secureboot/keys/db/db.key:/usr/share/secureboot/keys/db/db.pem"
		if [ "$LOADER" = systemd-boot ]; then
			CANDIDATES="$DBKEYS $MOKS"
		else
			CANDIDATES="$MOKS $DBKEYS"
		fi
		for pair in $CANDIDATES; do
			if [ -f "${pair%%:*}" ] && [ -f "${pair##*:}" ]; then
				KEY=${pair%%:*}
				CERT=${pair##*:}
				break
			fi
		done
	fi
	if [ -z "$KEY" ]; then
		[ "$SB" = 1 ] && die "Secure Boot is on and no signing key was found; see docs/SECURE-BOOT.md, then use --key/--cert"
		echo "Secure Boot is off and no key was found: installing unsigned."
		NOSIGN=1
	fi
fi

if [ "$NOSIGN" = 0 ]; then
	command -v sbsign >/dev/null || die "sbsign not found (package: sbsigntools / sbsigntool)"
	[ -f "$KEY" ] && [ -f "$CERT" ] || die "key or certificate not found"
	# Always write a real PEM file: sbsign needs PEM, and newer OpenSSL
	# auto-detects DER input, so "can openssl read it?" is not a PEM test.
	openssl x509 -in "$CERT" -outform PEM -out "$tmp/cert.pem" 2>/dev/null ||
		openssl x509 -inform DER -in "$CERT" -outform PEM -out "$tmp/cert.pem" ||
		die "cannot read certificate $CERT"
	if [ "$SB" = 1 ]; then
		FP=$(openssl x509 -in "$tmp/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)
		if mokutil --list-enrolled 2>/dev/null | grep -qiF "SHA1 Fingerprint: $FP"; then
			echo "signing key $FP is an enrolled MOK"
			# systemd-boot loads drivers with the firmware's LoadImage,
			# which checks db; a MOK is only honoured where shim hooks it.
			[ "$LOADER" = systemd-boot ] &&
				echo "NOTE: with systemd-boot a MOK-only key may be rejected; if so, systemd-boot skips tscsync and boots normally (see docs/SECURE-BOOT.md)."
		elif mokutil --db 2>/dev/null | grep -qiF "SHA1 Fingerprint: $FP"; then
			echo "signing key $FP is in the firmware's db"
		else
			die "certificate $CERT ($FP) is neither an enrolled MOK nor in db; see docs/SECURE-BOOT.md"
		fi
	fi
	note "signing $(basename "$EFI_BIN")"
	sbsign --key "$KEY" --cert "$tmp/cert.pem" --output "$tmp/tscsync.efi" "$EFI_BIN"
	sbverify --cert "$tmp/cert.pem" "$tmp/tscsync.efi"
fi

# --- install -----------------------------------------------------------------
note "installing files"
if [ "$LOADER" = grub ]; then
	note "backing up grubenv"
	[ -e "$GRUBENV" ] && [ ! -e "$GRUBENV.before-tscsync" ] && cp -a "$GRUBENV" "$GRUBENV.before-tscsync"
	[ -e "$GRUBENV" ] || "$EDITENV" "$GRUBENV" create
	install -d "$ESP/EFI/tscsync"
	install -m 0644 "$tmp/tscsync.efi" "$ESP/EFI/tscsync/tscsync.efi"
	sed "s/@ESP_UUID@/$ESP_UUID/" boot/custom.cfg.in >"$tmp/custom.cfg"
	command -v grub2-script-check >/dev/null && grub2-script-check "$tmp/custom.cfg"
	command -v grub-script-check >/dev/null && grub-script-check "$tmp/custom.cfg"
	install -m 0600 "$tmp/custom.cfg" "$CUSTOM"
	cat >"$tmp/tscsync.conf" <<EOF
# Written by tscsync install.sh; read by the other tscsync scripts.
LOADER=grub
GRUB_DIR=$GRUB_DIR
GRUBENV=$GRUBENV
EDITENV=$EDITENV
ESP=$ESP
ESP_UUID=$ESP_UUID
EOF
else
	# Options first and the driver last, so the driver never runs without them.
	install -d "$STATE_DIR" "$ESP/EFI/systemd/drivers"
	rm -f "$STATE_DIR/pending" "$STATE_DIR/disabled"
	printf 'mode=measure\n' >"$STATE_DIR/options"
	install -m 0644 "$tmp/tscsync.efi" "$DRIVER"
	cat >"$tmp/tscsync.conf" <<EOF
# Written by tscsync install.sh; read by the other tscsync scripts.
LOADER=systemd-boot
ESP=$ESP
ESP_UUID=$ESP_UUID
STATE_DIR=$STATE_DIR
DRIVER=$DRIVER
EOF
fi
install -m 0644 "$tmp/tscsync.conf" /etc/tscsync.conf
install -D -m 0755 boot/tscsync-report /usr/local/libexec/tscsync-report
install -m 0755 scripts/tscsync-status /usr/local/bin/tscsync-status
install -m 0644 boot/tscsync-report.service /etc/systemd/system/tscsync-report.service
command -v restorecon >/dev/null && restorecon -F ${CUSTOM:+"$CUSTOM"} /etc/tscsync.conf \
	/usr/local/libexec/tscsync-report /usr/local/bin/tscsync-status \
	/etc/systemd/system/tscsync-report.service 2>/dev/null || true
systemctl daemon-reload
systemctl reenable tscsync-report.service

note "enabling in measure mode"
if [ "$LOADER" = grub ]; then
	"$EDITENV" "$GRUBENV" set tscsync_enable=1 tscsync_mode=mode=measure tscsync_pending=0
	"$EDITENV" "$GRUBENV" list | grep '^tscsync'
else
	echo "options: $(cat "$STATE_DIR/options")"
fi

cat <<EOF

Installed in MEASURE mode (read-only).
  loader: $LOADER   ESP: $ESP ($ESP_UUID)   signed: $([ "$NOSIGN" = 1 ] && echo no || echo yes)
Next:
  1. Shut down fully, then power on.
  2. Run: tscsync-status
  3. If it shows APs out of sync, switch to sync: sudo scripts/set-mode.sh sync
EOF
