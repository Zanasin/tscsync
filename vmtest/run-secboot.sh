#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Opt-in Secure Boot OVMF smokes. Not run by default (heavy / needs CODE + tools).
#
# Boots q35+SMM with OVMF_CODE.secboot + an enrolled varstore, and checks that a
# signed tscsync image loads. Uses ephemeral PK/KEK/db by default (no sudo, no
# host keys). Override with secboot/sign.key + sign.pem and matching *-vars.fd,
# or TSCSYNC_SECBOOT_KEY / TSCSYNC_SECBOOT_CERT.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
secboot_dir=$here/vmtest/secboot

echo "== tscsync Secure Boot smokes (opt-in) =="
echo "Assets directory: $secboot_dir"

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- CODE firmware ----------------------------------------------------------
code=
if [ -r "$secboot_dir/OVMF_CODE.secboot.path" ]; then
	code=$(tr -d '\n' <"$secboot_dir/OVMF_CODE.secboot.path")
	[ -r "$code" ] || code=
fi
if [ -z "$code" ]; then
	for c in \
		/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
		/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd \
		/usr/share/edk2/ovmf/OVMF_CODE.secboot.4m.fd \
		/usr/share/OVMF/OVMF_CODE.secboot.fd \
		/usr/share/OVMF/OVMF_CODE.secboot.4m.fd \
		/usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.4m.fd; do
		[ -r "$c" ] && { code=$c; break; }
	done
fi
if [ -z "$code" ]; then
	echo "SKIP: no OVMF_CODE.secboot*.fd on this host (Arch: edk2-ovmf → /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd)."
	echo "See vmtest/README-secboot.md"
	exit 0
fi
echo "Using firmware: $code"

# --- tools / template / bootloader -----------------------------------------
for bin in qemu-system-x86_64 openssl sbsign; do
	have "$bin" || die "$bin not found (needed for Secure Boot smokes)"
done
have virt-fw-vars || die "virt-fw-vars not found (package: python-virt-firmware)"
have mkfs.vfat && have mcopy || die "dosfstools + mtools required"

template=
for t in \
	/usr/share/edk2/x64/OVMF_VARS.4m.fd \
	/usr/share/edk2/ovmf/OVMF_VARS.fd \
	/usr/share/edk2/ovmf/OVMF_VARS.4m.fd \
	/usr/share/OVMF/OVMF_VARS.fd \
	/usr/share/OVMF/OVMF_VARS.4m.fd; do
	[ -r "$t" ] && { template=$t; break; }
done
[ -n "$template" ] || die "no OVMF_VARS template found (same package as CODE)"

sdboot=
for s in \
	/usr/lib/systemd/boot/efi/systemd-bootx64.efi \
	/usr/lib/systemd/boot/efi/systemd-bootx64.efi.unsigned; do
	[ -r "$s" ] && { sdboot=$s; break; }
done
[ -n "$sdboot" ] || die "systemd-bootx64.efi not found (package: systemd-boot / systemd)"

make -C "$here" all >/dev/null
[ -r "$here/build/tscsync.efi" ] && [ -r "$here/build/tscsync-driver.efi" ] ||
	die "build/tscsync.efi or build/tscsync-driver.efi missing after make all"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
GUID=12345678-1234-1234-1234-123456789abc

# --- signing material + enrolled vars --------------------------------------
key= cert= vars_src=
if [ -n "${TSCSYNC_SECBOOT_KEY:-}" ] && [ -n "${TSCSYNC_SECBOOT_CERT:-}" ]; then
	key=$TSCSYNC_SECBOOT_KEY
	cert=$TSCSYNC_SECBOOT_CERT
elif [ -r "$secboot_dir/sign.key" ] && [ -r "$secboot_dir/sign.pem" ]; then
	key=$secboot_dir/sign.key
	cert=$secboot_dir/sign.pem
fi

if [ -n "$key" ]; then
	[ -r "$key" ] && [ -r "$cert" ] || die "signing key/cert not readable"
	if [ -r "$secboot_dir/sdboot-db-vars.fd" ]; then
		vars_src=$secboot_dir/sdboot-db-vars.fd
	elif [ -r "$secboot_dir/grub-mok-vars.fd" ]; then
		vars_src=$secboot_dir/grub-mok-vars.fd
	else
		echo "note: custom key set but no *-vars.fd; enrolling cert into a fresh varstore"
		virt-fw-vars -i "$template" -o "$T/enrolled-vars.fd" \
			--set-pk "$GUID" "$cert" --add-kek "$GUID" "$cert" --add-db "$GUID" "$cert" --sb >/dev/null 2>&1
		vars_src=$T/enrolled-vars.fd
	fi
	echo "Using provided signing key: $cert"
else
	echo "Generating ephemeral PK/KEK/db for this run"
	openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 \
		-subj "/CN=tscsync-secboot-smoke/" \
		-keyout "$T/db.key" -out "$T/db.pem" 2>/dev/null
	key=$T/db.key
	cert=$T/db.pem
	virt-fw-vars -i "$template" -o "$T/enrolled-vars.fd" \
		--set-pk "$GUID" "$cert" --add-kek "$GUID" "$cert" --add-db "$GUID" "$cert" --sb >/dev/null 2>&1
	vars_src=$T/enrolled-vars.fd
fi

sign_efi() { # $1=in $2=out
	sbsign --key "$key" --cert "$cert" --output "$2" "$1" >/dev/null 2>&1
}

sign_efi "$here/build/tscsync-driver.efi" "$T/tscsync-driver.signed.efi"
sign_efi "$here/build/tscsync.efi" "$T/tscsync.signed.efi"
sign_efi "$sdboot" "$T/BOOTX64.sdboot.efi"

# OVMF Secure Boot needs q35+SMM and secure pflash. disable_s3 is required by
# OVMF when SMM is on. Prefer KVM; if the guest produces no serial (SMM hang on
# some hosts), retry once under TCG. Serial goes to a file — never stdio — so
# QEMU cannot be SIGTTIN/SIGTSTP-stopped against the caller's tty.
use_kvm=0
if [ -c /dev/kvm ] && [ -w /dev/kvm ]; then
	use_kvm=1
	echo "accel: KVM available"
else
	echo "note: /dev/kvm not usable; using TCG"
fi

run_qemu() { # $1=accel_tag (kvm|tcg) $2=esp → sets $T/last.out and T_last_ec
	local tag=$1 esp=$2 accel limit smp
	rm -f "$T/serial.log" "$T/qemu.err"
	if [ "$tag" = kvm ]; then
		accel="-machine q35,smm=on,accel=kvm -cpu host"
		smp=4
		limit=60
	else
		accel="-machine q35,smm=on,accel=tcg -cpu max"
		smp=2
		limit=180
	fi
	set +e
	# stdin from /dev/null; serial to a file (not -nographic/-serial stdio).
	timeout "$limit" qemu-system-x86_64 $accel -smp "$smp" -m 512 \
		-global ICH9-LPC.disable_s3=1 \
		-global driver=cfi.pflash01,property=secure,value=on \
		-drive if=pflash,format=raw,unit=0,readonly=on,file="$code" \
		-drive if=pflash,format=raw,unit=1,file="$T/vars.fd" \
		-drive format=raw,file="$esp" \
		-display none -no-reboot -monitor none \
		-serial "file:$T/serial.log" \
		</dev/null >"$T/qemu.err" 2>&1
	T_last_ec=$?
	set -e
	{
		[ -s "$T/qemu.err" ] && cat "$T/qemu.err"
		[ -s "$T/serial.log" ] && cat "$T/serial.log"
	} >"$T/raw.out" 2>/dev/null || : >"$T/raw.out"
	tr -d '\r' <"$T/raw.out" | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' >"$T/last.out"
}

serial_looks_alive() {
	grep -aqE 'tscsync|RESULT|BdsDxe|Access denied|Failed to load|Security Violation' "$T/last.out"
}

boot_vm() { # $1=label $2=enrolled-vars $3=esp.img → writes $T/last.out; echoes filtered lines
	local label=$1 vars=$2 esp=$3 tag
	cp "$vars" "$T/vars.fd"
	echo
	echo "================ $label ================"
	if [ "$use_kvm" = 1 ]; then
		tag=kvm
	else
		tag=tcg
	fi
	run_qemu "$tag" "$esp"
	# KVM node can be fine while OVMF+SMM still hangs with empty serial.
	if [ "$tag" = kvm ] && ! serial_looks_alive; then
		echo "note: KVM was usable but guest produced no serial (exit $T_last_ec); retrying with TCG"
		cp "$vars" "$T/vars.fd"
		run_qemu tcg "$esp"
		tag=tcg
	fi
	grep -aE 'tscsync|RESULT|GRUB:|Failed|Access denied|Security Violation|error|refused|qemu-system|BdsDxe' "$T/last.out" || true
	echo "(VM exit status: $T_last_ec, accel=$tag)"
	return 0
}

dump_serial() {
	echo "---- serial (tail) ----" >&2
	tail -n 40 "$T/last.out" >&2 || true
}

expect_ran() { # $1=label
	if ! grep -qE 'tscsync [0-9]' "$T/last.out"; then
		dump_serial
		die "$1: signed image did not run (no tscsync banner)"
	fi
	if ! grep -q 'RESULT:' "$T/last.out"; then
		dump_serial
		die "$1: missing RESULT line"
	fi
	if grep -qiE 'Access denied|Security Violation' "$T/last.out"; then
		dump_serial
		die "$1: Secure Boot rejected the image"
	fi
	echo "OK: $1"
}

expect_denied() { # $1=label
	if grep -qE 'tscsync [0-9]' "$T/last.out"; then
		dump_serial
		die "$1: unsigned image ran under Secure Boot"
	fi
	if ! grep -qiE 'Access denied|Security Violation|Failed to load' "$T/last.out"; then
		dump_serial
		die "$1: expected Access denied / load failure for unsigned image"
	fi
	echo "OK: $1"
}

make_sdboot_esp() { # $1=driver.efi → $T/esp.img
	rm -f "$T/esp.img"
	truncate -s 64M "$T/esp.img"
	mkfs.vfat -F 32 "$T/esp.img" >/dev/null
	export MTOOLS_SKIP_CHECK=1
	mmd -i "$T/esp.img" ::/EFI ::/EFI/BOOT ::/EFI/systemd ::/EFI/systemd/drivers \
		::/EFI/tscsync ::/loader
	mcopy -i "$T/esp.img" "$T/BOOTX64.sdboot.efi" ::/EFI/BOOT/BOOTX64.EFI
	mcopy -i "$T/esp.img" "$1" ::/EFI/systemd/drivers/tscsyncx64.efi
	printf 'timeout 0\nauto-poweroff yes\ndefault auto-poweroff\n' >"$T/loader.conf"
	mcopy -i "$T/esp.img" "$T/loader.conf" ::/loader/loader.conf
	printf 'mode=measure\n' >"$T/options"
	mcopy -i "$T/esp.img" "$T/options" ::/EFI/tscsync/options
}

# --- 1. systemd-boot + signed driver ---------------------------------------
echo
echo "### 1. systemd-boot + signed driver (expect run)"
make_sdboot_esp "$T/tscsync-driver.signed.efi"
boot_vm "systemd-boot signed driver" "$vars_src" "$T/esp.img"
expect_ran "systemd-boot signed"

# --- 2. systemd-boot + unsigned driver (negative) --------------------------
echo
echo "### 2. systemd-boot + unsigned driver (expect Access denied)"
make_sdboot_esp "$here/build/tscsync-driver.efi"
boot_vm "systemd-boot unsigned driver" "$vars_src" "$T/esp.img"
expect_denied "systemd-boot unsigned"

# --- 3. GRUB + signed tscsync.efi (optional if grub-mkstandalone exists) ---
grub_mk=
if have grub2-mkstandalone; then
	grub_mk=grub2-mkstandalone
elif have grub-mkstandalone; then
	grub_mk=grub-mkstandalone
fi

if [ -n "$grub_mk" ]; then
	echo
	echo "### 3. GRUB + signed tscsync.efi (expect run)"
	ESP_UUID=1234-ABCD
	cat >"$T/embed.cfg" <<'EOF'
search --no-floppy --fs-uuid --set=root 1234-ABCD
set prefix=($root)/grub2
set config_directory=$prefix
load_env -f ${config_directory}/grubenv
echo "GRUB: before custom.cfg  enable=${tscsync_enable} mode=${tscsync_mode} pending=${tscsync_pending}"
source ${config_directory}/custom.cfg
load_env -f ${config_directory}/grubenv
echo "GRUB: after custom.cfg   enable=${tscsync_enable} mode=${tscsync_mode} pending=${tscsync_pending}"
echo "GRUB: script continued normally; this is where the boot menu would appear"
halt
EOF
	"$grub_mk" -O x86_64-efi -o "$T/BOOTX64.grub.unsigned" \
		--modules="part_gpt part_msdos fat search search_fs_uuid loadenv chain echo halt test normal configfile" \
		"boot/grub/grub.cfg=$T/embed.cfg" >/dev/null
	sign_efi "$T/BOOTX64.grub.unsigned" "$T/BOOTX64.grub.efi"
	sed "s/@ESP_UUID@/$ESP_UUID/" "$here/boot/custom.cfg.in" >"$T/custom.cfg"
	rm -f "$T/esp.img"
	truncate -s 64M "$T/esp.img"
	mkfs.vfat -F 32 -i "${ESP_UUID/-/}" "$T/esp.img" >/dev/null
	export MTOOLS_SKIP_CHECK=1
	mmd -i "$T/esp.img" ::/EFI ::/EFI/BOOT ::/EFI/tscsync ::/grub2
	mcopy -i "$T/esp.img" "$T/BOOTX64.grub.efi" ::/EFI/BOOT/BOOTX64.EFI
	mcopy -i "$T/esp.img" "$T/tscsync.signed.efi" ::/EFI/tscsync/tscsync.efi
	mcopy -i "$T/esp.img" "$T/custom.cfg" ::/grub2/custom.cfg
	if have grub2-editenv; then
		grub2-editenv "$T/grubenv" create
		grub2-editenv "$T/grubenv" set tscsync_enable=1 tscsync_mode=mode=measure tscsync_pending=0
	elif have grub-editenv; then
		grub-editenv "$T/grubenv" create
		grub-editenv "$T/grubenv" set tscsync_enable=1 tscsync_mode=mode=measure tscsync_pending=0
	else
		die "grub-editenv not found (needed with $grub_mk)"
	fi
	mcopy -i "$T/esp.img" "$T/grubenv" ::/grub2/grubenv
	boot_vm "GRUB signed tscsync.efi" "$vars_src" "$T/esp.img"
	expect_ran "GRUB signed"
else
	echo
	echo "SKIP: GRUB smoke (no grub-mkstandalone / grub2-mkstandalone on PATH)"
	echo "      Install grub and re-run, or rely on the systemd-boot smokes above."
fi

echo
echo "RESULT: Secure Boot smokes passed"
