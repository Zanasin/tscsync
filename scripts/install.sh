#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Install tscsync in MEASURE mode (read-only: it writes nothing to the CPU).
# Reinstalling (for example after git pull) keeps the current mode, measure or
# sync with its options, unless tscsync was off; then it starts in measure.
#
# Usage: sudo scripts/install.sh [options]
#   --measure                start in measure mode even when reinstalling
#   --key FILE --cert FILE   Secure Boot signing key and certificate (PEM key,
#                            PEM or DER cert) enrolled as a MOK or in db
#   --no-sign                install unsigned (only if Secure Boot is off, or
#                            you sign the .efi yourself, e.g. with sbctl)
#   --loader grub|systemd-boot|refind
#                            boot loader to hook into (default: detected)
#   --esp DIR                EFI system partition mount point
#   --grub-dir DIR           GRUB config directory (holding grub.cfg)
#   --refind-dir DIR         rEFInd directory on the ESP (holding refind.conf)
#
# What it changes, all reversible with scripts/uninstall.sh:
#   GRUB:          <ESP>/EFI/tscsync/tscsync.efi
#                  <grub-dir>/custom.cfg           sourced by grub.cfg (41_custom)
#                  grubenv: tscsync_enable=1 tscsync_mode=mode=measure tscsync_pending=0
#   systemd-boot:  <ESP>/EFI/systemd/drivers/tscsyncx64.efi
#                  <ESP>/EFI/tscsync/options       "mode=measure"
#   rEFInd:        <refind-dir>/drivers_x64/tscsyncx64.efi
#                  <ESP>/EFI/tscsync/options       "mode=measure exit=success"
#   all:          /usr/local/libexec/tscsync-report     clears the hang guard after boot
#                  /usr/local/bin/tscsync-status         status command
#                  /etc/systemd/system/tscsync-report.service
#                    (RequiresMountsFor= set to the hang-guard filesystem:
#                     grubenv's mount for GRUB, or the ESP for drivers)
#                  /etc/tscsync.conf                     paths detected here
# It does not modify grub.cfg, loader.conf, refind.conf, boot entries, the
# kernel command line, or firmware settings.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR/.."

die() { echo "install.sh: $*" >&2; exit 1; }
note() { echo "== $*"; }

KEY= CERT= NOSIGN=0 ESP= GRUB_DIR= REFIND_DIR= LOADER= CUSTOM= RESET=0
while [ $# -gt 0 ]; do
	case "$1" in
	--key) KEY=$2; shift 2 ;;
	--cert) CERT=$2; shift 2 ;;
	--no-sign) NOSIGN=1; shift ;;
	--loader) LOADER=$2; shift 2 ;;
	--esp) ESP=$2; shift 2 ;;
	--grub-dir) GRUB_DIR=$2; shift 2 ;;
	--refind-dir) REFIND_DIR=$2; shift 2 ;;
	--measure) RESET=1; shift ;;
	-h | --help) sed -n '3,/^[^#]/{/^#/p}' "$0"; exit 0 ;;
	*) die "unknown option $1 (see --help)" ;;
	esac
done

[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(uname -m)" = x86_64 ] || die "only x86_64 is supported"
[ -d /sys/firmware/efi ] || die "not booted in UEFI mode"
command -v systemctl >/dev/null || die "systemd is required (it clears the hang guard after boot)"
# The mode set-mode.sh last wrote, if tscsync is on: "mode=sync allow=any-cpu".
# Off (set-mode off, or the hang guard) gives nothing, so the reinstall starts
# in measure mode, as a first install does.
current_mode() (
	# shellcheck source=/dev/null
	. /etc/tscsync.conf
	if [ "${LOADER:-grub}" = grub ]; then
		env=$("$EDITENV" "$GRUBENV" list 2>/dev/null) || exit 0
		grep -qx 'tscsync_enable=1' <<<"$env" || exit 0
		sed -n 's/^tscsync_mode=//p' <<<"$env"
	else
		[ -r "$STATE_DIR/options" ] && [ ! -e "$STATE_DIR/disabled" ] || exit 0
		sed 's/ exit=success//' "$STATE_DIR/options"
	fi
)
OLD_MODE= OLD_EXIT=
if [ -e /etc/tscsync.conf ]; then
	# shellcheck source=/dev/null
	OLD_LOADER=$(. /etc/tscsync.conf; echo "${LOADER:-grub}")
	OLD_MODE=$(current_mode | head -n1)
	# shellcheck source=/dev/null
	OLD_EXIT=$(. /etc/tscsync.conf; [ -n "${STATE_DIR:-}" ] &&
		grep -qw 'exit=success' "$STATE_DIR/options" 2>/dev/null && echo " exit=success" || true)
fi
MODE=mode=measure
if [ "$RESET" = 0 ] && [[ "$OLD_MODE" =~ ^mode=(measure|sync)( allow=any-cpu)?$ ]]; then
	MODE=$OLD_MODE
elif [ -n "${OLD_LOADER:-}" ] && [ "$RESET" = 0 ]; then
	note "tscsync was off (set-mode off, or the hang guard); reinstalling in measure mode"
fi

# --- boot loader -------------------------------------------------------------
EFIVARS=${TSCSYNC_EFIVARS:-/sys/firmware/efi/efivars}	# override only for tests
GV=8be4df61-93ca-11d2-aa0d-00e098032b8c	# EFI global variable GUID
# shellcheck source=install-policy.inc.sh
. "$SCRIPT_DIR/install-policy.inc.sh"
# Evidence (BootCurrent / LoaderInfo) first, then grub.cfg, then a rEFInd
# install on the ESP (see install-policy.inc.sh).
tscsync_detect_loader
case "$LOADER" in
grub | systemd-boot | refind) ;;
*) die "--loader must be grub, systemd-boot or refind" ;;
esac
[ -n "${OLD_LOADER:-}" ] && [ "$OLD_LOADER" != "$LOADER" ] &&
	die "tscsync is installed for $OLD_LOADER; run scripts/uninstall.sh first"
note "boot loader: $LOADER"

EFI_BIN=build/tscsync.efi
[ "$LOADER" != grub ] && EFI_BIN=build/tscsync-driver.efi
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

# --- rEFInd ----------------------------------------------------------------
# rEFInd loads every driver in drivers_<arch> (or drivers) next to its binary
# and refind.conf, usually EFI/refind, sometimes EFI/BOOT.
if [ "$LOADER" = refind ]; then
	if [ -z "$REFIND_DIR" ]; then
		if [ -f "$ESP/EFI/refind/refind.conf" ]; then
			REFIND_DIR=$ESP/EFI/refind
		else
			for d in "$ESP"/EFI/*/; do
				[ -f "${d}refind.conf" ] && { REFIND_DIR=${d%/}; break; }
			done
		fi
	fi
	[ -n "$REFIND_DIR" ] && [ -f "$REFIND_DIR/refind.conf" ] ||
		die "no rEFInd install found on $ESP (no refind.conf); use --refind-dir"
	STATE_DIR=$ESP/EFI/tscsync
	DRIVER=$REFIND_DIR/drivers_x64/tscsyncx64.efi
	if [ -e "$DRIVER" ] && [ ! -e "$STATE_DIR/options" ]; then
		die "$DRIVER already exists and was not installed by tscsync; not touching it"
	fi
fi

# --- Secure Boot signing ---------------------------------------------------
SB=0
if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
	SB=1
elif [ -r "$EFIVARS/SecureBoot-$GV" ] &&
	[ "$(od -An -tu1 -j4 -N1 "$EFIVARS/SecureBoot-$GV" | tr -d ' ')" = 1 ]; then
	SB=1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$EFI_BIN" "$tmp/tscsync.efi"

if [ "$NOSIGN" = 1 ]; then
	[ "$SB" = 1 ] && echo "WARNING: Secure Boot is on and --no-sign was given; the boot loader will refuse the tool unless you sign it yourself."
else
	if [ -z "$KEY" ]; then
		# Prefer an *enrolled* key (skip leftover DKMS MOK, etc.). Order depends
		# on loader: GRUB prefers MOK then db; systemd-boot/rEFInd prefer db then MOK.
		if tscsync_pick_signing_key; then
			:
		fi
		# With Secure Boot off, signing with a key found lying around is only a
		# convenience for turning it on later, so a missing sbsign must not stop
		# the install.
		if [ -n "$KEY" ] && [ "$SB" = 0 ] && ! command -v sbsign >/dev/null; then
			echo "Secure Boot is off and sbsign is not installed: installing unsigned (found $KEY; install sbsigntools to sign with it)."
			KEY= CERT=
			NOSIGN=1
		fi
	fi
	if [ -z "$KEY" ] && [ "$NOSIGN" = 0 ]; then
		[ "$SB" = 1 ] && die "Secure Boot is on and no usable enrolled signing key was found; see docs/SECURE-BOOT.md, then use --key/--cert or --no-sign + sbctl sign -s"
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
		FP=$(tscsync_cert_fingerprint "$tmp/cert.pem")
		if how=$(tscsync_cert_is_trusted "$FP" "$tmp/cert.pem" "$CERT"); then
			echo "signing key $FP is trusted ($how)"
			[ "$LOADER" = systemd-boot ] && [[ "$how" == enrolled-MOK ]] &&
				echo "NOTE: with systemd-boot a MOK-only key may be rejected; if so, systemd-boot skips tscsync and boots normally (see docs/SECURE-BOOT.md)."
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
	# rEFInd shows EFI_ABORTED (systemd-boot's quiet unload) as an error, so it
	# gets exit=success.
	install -d "$STATE_DIR" "$(dirname "$DRIVER")"
	rm -f "$STATE_DIR/pending" "$STATE_DIR/disabled"
	# A reinstall also keeps exit=success if it was set by hand.
	EXIT_TOK=$OLD_EXIT
	[ "$LOADER" = refind ] && EXIT_TOK=" exit=success"
	printf '%s%s\n' "$MODE" "$EXIT_TOK" >"$STATE_DIR/options"
	install -m 0644 "$tmp/tscsync.efi" "$DRIVER"
	cat >"$tmp/tscsync.conf" <<EOF
# Written by tscsync install.sh; read by the other tscsync scripts.
LOADER=$LOADER
ESP=$ESP
ESP_UUID=$ESP_UUID
STATE_DIR=$STATE_DIR
DRIVER=$DRIVER
EOF
fi
install -m 0644 "$tmp/tscsync.conf" /etc/tscsync.conf
install -D -m 0755 boot/tscsync-report /usr/local/libexec/tscsync-report
install -m 0755 scripts/tscsync-status /usr/local/bin/tscsync-status
# Hang guard lives on grubenv (GRUB) or EFI/tscsync on the ESP (drivers).
# Hardcoding /boot breaks installs whose ESP is /boot/efi or /efi.
if [ "$LOADER" = grub ]; then
	REQUIRES_MOUNTS=$(findmnt -no TARGET -T "$GRUBENV")
else
	REQUIRES_MOUNTS=$(findmnt -no TARGET -T "$STATE_DIR")
fi
[ -n "$REQUIRES_MOUNTS" ] || die "cannot find the mount point for the hang guard"
sed "s|@REQUIRES_MOUNTS@|$REQUIRES_MOUNTS|" boot/tscsync-report.service.in >"$tmp/tscsync-report.service"
install -m 0644 "$tmp/tscsync-report.service" /etc/systemd/system/tscsync-report.service
command -v restorecon >/dev/null && restorecon -F ${CUSTOM:+"$CUSTOM"} /etc/tscsync.conf \
	/usr/local/libexec/tscsync-report /usr/local/bin/tscsync-status \
	/etc/systemd/system/tscsync-report.service 2>/dev/null || true
systemctl daemon-reload
systemctl reenable tscsync-report.service

note "enabling: $MODE"
if [ "$LOADER" = grub ]; then
	"$EDITENV" "$GRUBENV" set tscsync_enable=1 "tscsync_mode=$MODE" tscsync_pending=0
	"$EDITENV" "$GRUBENV" list | grep '^tscsync'
else
	echo "options: $(cat "$STATE_DIR/options")"
fi

if [ "$MODE" != mode=measure ]; then
	cat <<EOF

Reinstalled, keeping the current mode: $MODE
  loader: $LOADER   ESP: $ESP ($ESP_UUID)   signed: $([ "$NOSIGN" = 1 ] && echo no || echo yes)
To start over in measure mode: sudo scripts/set-mode.sh measure
EOF
	exit 0
fi
cat <<EOF

Installed in MEASURE mode (read-only).
  loader: $LOADER   ESP: $ESP ($ESP_UUID)   signed: $([ "$NOSIGN" = 1 ] && echo no || echo yes)
Next:
  1. Shut down fully, then power on.
  2. Run: tscsync-status
  3. If it shows APs out of sync, switch to sync: sudo scripts/set-mode.sh sync
EOF
