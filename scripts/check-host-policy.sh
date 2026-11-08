#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Read-only host smoke: loader detect + signing key pick against real keys.
# Needs root (sbctl db key/cert are mode 0400). Does not write the ESP or
# /etc/tscsync.conf. Run: sudo make check-host
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die() { echo "check-host-policy: $*" >&2; exit 1; }
note() { echo "== $*"; }

[ "$(id -u)" = 0 ] || die "run as root (sudo make check-host)"
[ -d /sys/firmware/efi ] || die "not UEFI"

# shellcheck source=install-policy.inc.sh
. "$HERE/install-policy.inc.sh"

EFIVARS=${TSCSYNC_EFIVARS:-/sys/firmware/efi/efivars}
GV=8be4df61-93ca-11d2-aa0d-00e098032b8c
LOADER= GRUB_DIR= ESP=

note "detecting boot loader"
tscsync_detect_loader
echo "LOADER=$LOADER"
case "$LOADER" in
grub | systemd-boot | refind) ;;
*) die "unexpected LOADER=$LOADER" ;;
esac

SB=0
if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
	SB=1
elif [ -r "$EFIVARS/SecureBoot-$GV" ] &&
	[ "$(od -An -tu1 -j4 -N1 "$EFIVARS/SecureBoot-$GV" | tr -d ' ')" = 1 ]; then
	SB=1
fi
echo "SecureBoot=$SB"

KEY= CERT= NOSIGN=0
note "picking signing key (read-only)"
if ! tscsync_pick_signing_key; then
	if [ "$SB" = 1 ]; then
		die "no usable enrolled signing key (SB on)"
	fi
	echo "no key found (SB off) — OK for unsigned install path"
	echo "check-host-policy: OK"
	exit 0
fi
echo "KEY=$KEY"
echo "CERT=$CERT"
[ -r "$KEY" ] && [ -r "$CERT" ] || die "chosen key/cert not readable"

# On sbctl hosts with leftover DKMS, expect db for rEFInd/systemd-boot.
if [ -f /var/lib/sbctl/keys/db/db.pem ] && [ -f /var/lib/dkms/mok.pub ]; then
	case "$LOADER" in
	refind | systemd-boot)
		[[ "$CERT" == */sbctl/keys/db/db.pem ]] ||
			die "expected sbctl db cert for $LOADER when both sbctl and DKMS keys exist; got $CERT"
		note "assert ok: $LOADER prefers sbctl db over leftover DKMS"
		;;
	esac
fi

# If sbctl db was chosen, fingerprint should be trusted.
if [[ "$CERT" == */sbctl/keys/db/db.pem ]]; then
	pem=$(mktemp)
	trap 'rm -f "$pem"' EXIT
	openssl x509 -in "$CERT" -outform PEM -out "$pem"
	fp=$(tscsync_cert_fingerprint "$pem")
	how=$(tscsync_cert_is_trusted "$fp" "$pem" "$CERT") || die "sbctl db cert not trusted by policy ($fp)"
	echo "sbctl db trust=$how fp=$fp"
fi

echo "check-host-policy: OK (no ESP writes)"
