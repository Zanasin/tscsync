#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Layer A: unit tests for loader detect + signing key pick (no root, no ESP writes).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
pass() { echo "ok - $*"; }
die() { echo "install.sh: $*" >&2; exit 1; }	# match install.sh for sourced policy
# shellcheck source=install-policy.inc.sh
. "$HERE/install-policy.inc.sh"

make_cert_pair() {
	local dir=$1 cn=$2
	mkdir -p "$dir"
	openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 \
		-subj "/CN=$cn/" -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
}

write_bootcurrent_refind() {
	local efivars=$1
	mkdir -p "$efivars"
	# BootCurrent = 0001 (little-endian uint16 after 4-byte attr)
	printf '....\x01\x00' >"$efivars/BootCurrent-$GV"
	# Fake Boot0001 with "refind" in UCS-2-ish/ascii mix: tr -d NUL then grep -qi refind
	# Store ASCII "refind" after attrs so tr -d '\000' finds it.
	printf '....refind' >"$efivars/Boot0001-$GV"
}

write_loaderinfo_sdboot() {
	local efivars=$1
	mkdir -p "$efivars"
	printf '....systemd-boot 257' >"$efivars/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
}

mock_mokutil_enrolled() {
	local fp=$1
	cat >"$T/mokutil" <<EOF
#!/usr/bin/bash
case "\$1" in
--list-enrolled) echo "SHA1 Fingerprint: $fp" ;;
--db) exit 0 ;;
--sb-state) echo "SecureBoot enabled" ;;
*) exit 0 ;;
esac
EOF
	chmod +x "$T/mokutil"
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
GV=8be4df61-93ca-11d2-aa0d-00e098032b8c
failures=0

run() {
	local name=$1
	shift
	if "$@"; then
		pass "$name"
	else
		echo "FAIL: $name" >&2
		failures=$((failures + 1))
	fi
}

# --- detect: BootCurrent rEFInd wins even if grub.cfg exists ---
case_refind_evidence() {
	local root=$T/r1
	mkdir -p "$root/boot/grub" "$root/efivars"
	echo ok >"$root/boot/grub/grub.cfg"
	write_bootcurrent_refind "$root/efivars"
	EFIVARS=$root/efivars TSCSYNC_ROOT=$root LOADER= GRUB_DIR= ESP=
	tscsync_detect_loader
	[ "$LOADER" = refind ]
}
run "detect: BootCurrent=rEFInd beats grub.cfg" case_refind_evidence

# --- detect: LoaderInfo systemd-boot ---
case_sd_evidence() {
	local root=$T/r2
	mkdir -p "$root/efivars"
	write_loaderinfo_sdboot "$root/efivars"
	EFIVARS=$root/efivars TSCSYNC_ROOT=$root LOADER= GRUB_DIR= ESP=
	tscsync_detect_loader
	[ "$LOADER" = systemd-boot ]
}
run "detect: LoaderInfo=systemd-boot" case_sd_evidence

# --- detect: ambiguous → grub ---
case_fallback_grub() {
	local root=$T/r3
	mkdir -p "$root/boot/grub" "$root/efivars"
	echo ok >"$root/boot/grub/grub.cfg"
	EFIVARS=$root/efivars TSCSYNC_ROOT=$root LOADER= GRUB_DIR= ESP=
	tscsync_detect_loader
	[ "$LOADER" = grub ]
}
run "detect: fallback grub.cfg" case_fallback_grub

# --- detect: EFI/systemd without LoaderInfo is not a guess (systemd-boot didn't run) ---
case_no_guess_sd() {
	local root=$T/r4
	mkdir -p "$root/boot/efi/EFI/systemd" "$root/efivars"
	EFIVARS=$root/efivars TSCSYNC_ROOT=$root LOADER= GRUB_DIR= ESP=
	! (tscsync_detect_loader) >/dev/null 2>&1
}
run "detect: EFI/systemd alone refuses (asks for --loader)" case_no_guess_sd

# --- detect: ambiguous → rEFInd on ESP ---
case_fallback_refind() {
	local root=$T/r5
	mkdir -p "$root/boot/efi/EFI/refind" "$root/efivars"
	echo ok >"$root/boot/efi/EFI/refind/refind.conf"
	EFIVARS=$root/efivars TSCSYNC_ROOT=$root LOADER= GRUB_DIR= ESP=
	tscsync_detect_loader
	[ "$LOADER" = refind ]
}
run "detect: fallback refind.conf" case_fallback_refind

# --- signing: SB on, DKMS unenrolled + sbctl enrolled, loader=refind → sbctl ---
case_sign_refind_sbctl() {
	local root=$T/s1
	mkdir -p "$root/var/lib/dkms" "$root/var/lib/sbctl/keys/db"
	make_cert_pair "$root/var/lib/dkms" "leftover-dkms"
	mv "$root/var/lib/dkms/key.pem" "$root/var/lib/dkms/mok.key"
	mv "$root/var/lib/dkms/cert.pem" "$root/var/lib/dkms/mok.pub"
	make_cert_pair "$root/var/lib/sbctl/keys/db" "sbctl-db"
	mv "$root/var/lib/sbctl/keys/db/key.pem" "$root/var/lib/sbctl/keys/db/db.key"
	mv "$root/var/lib/sbctl/keys/db/cert.pem" "$root/var/lib/sbctl/keys/db/db.pem"
	local fp
	fp=$(openssl x509 -in "$root/var/lib/sbctl/keys/db/db.pem" -noout -fingerprint -sha1 | cut -d= -f2)
	mock_mokutil_enrolled "$fp"
	# Only enroll sbctl fp in mokutil --db style via custom mock:
	cat >"$T/mokutil" <<EOF
#!/usr/bin/bash
case "\$1" in
--list-enrolled) exit 0 ;;
--db) echo "SHA1 Fingerprint: $fp" ;;
*) exit 0 ;;
esac
EOF
	chmod +x "$T/mokutil"
	TSCSYNC_ROOT=$root TSCSYNC_MOKUTIL=$T/mokutil \
		LOADER=refind SB=1 KEY= CERT= NOSIGN=0
	tscsync_pick_signing_key >/dev/null
	[[ "$CERT" == *sbctl/keys/db/db.pem ]]
}
run "sign: refind prefers enrolled sbctl over leftover DKMS" case_sign_refind_sbctl

# --- signing: SB on, sbctl installed but its db key not enrolled → no key ---
case_sign_sbctl_not_enrolled() {
	local root=$T/s5
	mkdir -p "$root/var/lib/sbctl/keys/db" "$T/sbctl-bin"
	make_cert_pair "$root/var/lib/sbctl/keys/db" "sbctl-db-unenrolled"
	mv "$root/var/lib/sbctl/keys/db/key.pem" "$root/var/lib/sbctl/keys/db/db.key"
	mv "$root/var/lib/sbctl/keys/db/cert.pem" "$root/var/lib/sbctl/keys/db/db.pem"
	cat >"$T/sbctl-bin/sbctl" <<'EOF'
#!/usr/bin/bash
echo "Installed:	✓ sbctl is installed"
EOF
	chmod +x "$T/sbctl-bin/sbctl"
	printf '#!/usr/bin/bash\nexit 0\n' >"$T/mokutil"
	chmod +x "$T/mokutil"
	PATH=$T/sbctl-bin:$PATH TSCSYNC_ROOT=$root TSCSYNC_MOKUTIL=$T/mokutil \
		LOADER=refind SB=1 KEY= CERT= NOSIGN=0
	! tscsync_pick_signing_key >/dev/null 2>&1
}
run "sign: sbctl installed but db key not enrolled is skipped" case_sign_sbctl_not_enrolled

# --- signing: SB on, enrolled MOK only, loader=grub → MOK ---
case_sign_grub_mok() {
	local root=$T/s2
	mkdir -p "$root/var/lib/dkms"
	make_cert_pair "$root/var/lib/dkms" "good-mok"
	mv "$root/var/lib/dkms/key.pem" "$root/var/lib/dkms/mok.key"
	mv "$root/var/lib/dkms/cert.pem" "$root/var/lib/dkms/mok.pub"
	local fp
	fp=$(openssl x509 -in "$root/var/lib/dkms/mok.pub" -noout -fingerprint -sha1 | cut -d= -f2)
	cat >"$T/mokutil" <<EOF
#!/usr/bin/bash
case "\$1" in
--list-enrolled) echo "SHA1 Fingerprint: $fp" ;;
--db) exit 0 ;;
*) exit 0 ;;
esac
EOF
	chmod +x "$T/mokutil"
	TSCSYNC_ROOT=$root TSCSYNC_MOKUTIL=$T/mokutil \
		LOADER=grub SB=1 KEY= CERT= NOSIGN=0
	tscsync_pick_signing_key >/dev/null
	[[ "$CERT" == *dkms/mok.pub ]]
}
run "sign: grub uses enrolled MOK" case_sign_grub_mok

# --- signing: SB on, only unenrolled DKMS → fail pick ---
case_sign_skip_unenrolled() {
	local root=$T/s3
	mkdir -p "$root/var/lib/dkms"
	make_cert_pair "$root/var/lib/dkms" "bad-mok"
	mv "$root/var/lib/dkms/key.pem" "$root/var/lib/dkms/mok.key"
	mv "$root/var/lib/dkms/cert.pem" "$root/var/lib/dkms/mok.pub"
	cat >"$T/mokutil" <<'EOF'
#!/usr/bin/bash
exit 0
EOF
	chmod +x "$T/mokutil"
	TSCSYNC_ROOT=$root TSCSYNC_MOKUTIL=$T/mokutil \
		LOADER=grub SB=1 KEY= CERT= NOSIGN=0
	! tscsync_pick_signing_key >/dev/null 2>&1
}
run "sign: SB on skips unenrolled DKMS" case_sign_skip_unenrolled

# --- signing: SB off picks first existing key ---
case_sign_sb_off() {
	local root=$T/s4
	mkdir -p "$root/var/lib/dkms"
	make_cert_pair "$root/var/lib/dkms" "any"
	mv "$root/var/lib/dkms/key.pem" "$root/var/lib/dkms/mok.key"
	mv "$root/var/lib/dkms/cert.pem" "$root/var/lib/dkms/mok.pub"
	TSCSYNC_ROOT=$root TSCSYNC_MOKUTIL=/bin/true \
		LOADER=grub SB=0 KEY= CERT= NOSIGN=0
	tscsync_pick_signing_key >/dev/null
	[ -n "$KEY" ]
}
run "sign: SB off accepts first existing key" case_sign_sb_off

if [ "$failures" -ne 0 ]; then
	echo "$failures test(s) failed" >&2
	exit 1
fi
echo "All install-policy tests passed."
