#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Runs inside a throwaway container built from vmtest/Containerfile: boots
# GRUB + tscsync, then systemd-boot + the tscsync driver, in KVM VMs with
# OVMF and 8 vCPUs, exercising the real custom.cfg snippet, the systemd-boot
# state files and both hang guards. Started by vmtest/run.sh.
set -euo pipefail

W=/work
T=$(mktemp -d)
ESP_UUID=1234-ABCD	# test volume ID; the snippet is used exactly as installed

# GRUB standalone image. Its embedded config mirrors Fedora's grub.cfg order:
# load grubenv from the config directory, then source custom.cfg.
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
grub2-mkstandalone -O x86_64-efi -o "$T/BOOTX64.EFI" \
	--modules="part_gpt part_msdos fat search search_fs_uuid loadenv chain echo halt test normal configfile" \
	"boot/grub/grub.cfg=$T/embed.cfg" >/dev/null

sed "s/@ESP_UUID@/$ESP_UUID/" "$W/boot/custom.cfg.in" >"$T/custom.cfg"

make_disk() {	# $1 = efi binary to install as tscsync.efi
	rm -f "$T/esp.img"
	truncate -s 64M "$T/esp.img"
	mkfs.vfat -F 32 -i "${ESP_UUID/-/}" "$T/esp.img" >/dev/null
	export MTOOLS_SKIP_CHECK=1
	mmd -i "$T/esp.img" ::/EFI ::/EFI/BOOT ::/EFI/tscsync ::/grub2
	mcopy -i "$T/esp.img" "$T/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
	mcopy -i "$T/esp.img" "$1" ::/EFI/tscsync/tscsync.efi
	mcopy -i "$T/esp.img" "$T/custom.cfg" ::/grub2/custom.cfg
}

set_env() {	# "$@" = name=value pairs
	mcopy -n -i "$T/esp.img" ::/grub2/grubenv "$T/grubenv" 2>/dev/null || grub2-editenv "$T/grubenv" create
	grub2-editenv "$T/grubenv" set "$@"
	mcopy -o -i "$T/esp.img" "$T/grubenv" ::/grub2/grubenv
	rm -f "$T/grubenv"
}

boot_vm() {	# $1 = label, $2 = kvm (default) or tcg
	# KVM on a host whose own TSC is marked unstable re-bases guest TSCs
	# whenever a vCPU is rescheduled, so TSC-accuracy tests use TCG pinned
	# to host CPUs 1-15 (one CCD, whose TSCs agree).
	local accel="-machine q35,accel=kvm -cpu host" pin="" limit=180
	if [ "${2:-kvm}" = tcg ]; then
		accel="-machine q35 -accel tcg,thread=multi -cpu EPYC-Genoa"
		pin="taskset -c 1-15"
		limit=900
	elif [ "${2:-kvm}" = kvm-pinned ]; then
		# vCPUs never halt out of the guest (cpu-pm=on), so KVM does not
		# re-base their TSCs; host CPU 0 (the laggard) is avoided.
		accel="-machine q35,accel=kvm -cpu host -overcommit cpu-pm=on"
		pin="taskset -c 1-7,16"
	fi
	echo
	echo "================ $1 (${2:-kvm}) ================"
	cp /usr/share/edk2/ovmf/OVMF_VARS.fd "$T/vars.fd"
	timeout $limit $pin qemu-system-x86_64 $accel -smp 8 -m 1024 \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
		-drive if=pflash,format=raw,file="$T/vars.fd" \
		-drive format=raw,file="$T/esp.img" \
		-nographic -no-reboot -monitor none -serial stdio 2>&1 |
		tr -d '\r' | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' |
		grep -E 'GRUB:|tscsync|Failed|not a driver|TEST BUILD|cpu:|processors:|survey|verify|AP pass|APs vs|moving BSP|bsp vs|cpu +[0-9]+ apic|ok, |RESULT|error|refused|skipped|disabling|qemu-system| ms\)|total|busy' || true
	echo "(VM exit status: ${PIPESTATUS[0]})"
}

echo "### 1. production build, mode=measure (read-only)"
make_disk "$W/build/tscsync.efi"
set_env tscsync_enable=1 tscsync_mode=mode=measure tscsync_pending=0
boot_vm "production tscsync.efi, measure"

echo "### 1b. production build, measure, pinned KVM (baseline noise)"
set_env tscsync_pending=0
boot_vm "production tscsync.efi, measure" kvm-pinned

echo "### 2. production build, mode=sync (VM TSCs already in sync: expect no writes)"
set_env tscsync_pending=0 tscsync_mode=mode=sync
boot_vm "production tscsync.efi, sync"

echo "### 3. test build: BSP set back by the Legion's warp (real pattern), then sync + verify"
make_disk "$W/build/tscsync-test.efi"
set_env tscsync_enable=1 tscsync_mode=mode=sync tscsync_pending=0
boot_vm "TEST BSP-behind, sync" kvm-pinned

echo "### 3b. test build: every AP set back instead, then sync + verify"
set_env tscsync_enable=1 "tscsync_mode=mode=sync test=ap-behind" tscsync_pending=0
boot_vm "TEST AP-behind, sync" kvm-pinned

echo "### 3c. test build: odd APs ahead of the BSP, even APs behind (mixed pattern)"
set_env tscsync_enable=1 "tscsync_mode=mode=sync test=mixed" tscsync_pending=0
boot_vm "TEST mixed, sync" kvm-pinned

echo "### 4. hang guard: previous boot left pending=1 (Linux never cleared it)"
boot_vm "guard: expect skip + disable"

echo "### 5. after the guard disabled it: expect tscsync not to run"
boot_vm "guard: disabled"

# --- systemd-boot: the driver build, loaded from EFI/systemd/drivers ---------
make_sdboot_disk() {	# $1 = driver binary, $2 = options line
	rm -f "$T/esp.img"
	truncate -s 64M "$T/esp.img"
	mkfs.vfat -F 32 -i "${ESP_UUID/-/}" "$T/esp.img" >/dev/null
	export MTOOLS_SKIP_CHECK=1
	mmd -i "$T/esp.img" ::/EFI ::/EFI/BOOT ::/EFI/systemd ::/EFI/systemd/drivers \
		::/EFI/tscsync ::/loader
	mcopy -i "$T/esp.img" /usr/lib/systemd/boot/efi/systemd-bootx64.efi ::/EFI/BOOT/BOOTX64.EFI
	mcopy -i "$T/esp.img" "$1" ::/EFI/systemd/drivers/tscsyncx64.efi
	# No boot entries: power off right after the drivers have run.
	printf 'timeout 0\nauto-poweroff yes\ndefault auto-poweroff\n' >"$T/loader.conf"
	mcopy -i "$T/esp.img" "$T/loader.conf" ::/loader/loader.conf
	set_options "$2"
}

set_options() {	# $1 = options line, as scripts/set-mode.sh writes it
	printf '%s\n' "$1" >"$T/options"
	mcopy -o -i "$T/esp.img" "$T/options" ::/EFI/tscsync/options
}

state() {	# which tscsync state files exist on the ESP
	echo "ESP state: $(mdir -b -i "$T/esp.img" ::/EFI/tscsync 2>/dev/null |
		sed 's|.*/||' | sort | tr '\n' ' ')"
}

linux_booted() {	# what tscsync-report.service does once Linux is up
	mdel -i "$T/esp.img" ::/EFI/tscsync/pending 2>/dev/null || true
}

echo
echo "### 6. systemd-boot, production driver, measure (read-only)"
make_sdboot_disk "$W/build/tscsync-driver.efi" "mode=measure"
boot_vm "systemd-boot: production driver, measure"
state
linux_booted

echo "### 7. systemd-boot, test driver: BSP set back by the Legion's warp, then sync + verify"
make_sdboot_disk "$W/build/tscsync-test-driver.efi" "mode=sync"
boot_vm "systemd-boot: TEST BSP-behind, sync" kvm-pinned
state

echo "### 8. systemd-boot hang guard: pending left by the last boot (Linux never cleared it)"
boot_vm "systemd-boot guard: expect skip + disable"
state

echo "### 9. systemd-boot after the guard disabled it: expect tscsync not to run"
boot_vm "systemd-boot guard: disabled"
state
