#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Opt-in Secure Boot OVMF smokes. Not run by default (heavy / needs enrolled vars).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
secboot_dir=$here/vmtest/secboot

echo "== tscsync Secure Boot smokes (opt-in) =="
echo "Assets directory: $secboot_dir"

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

need_vars=0
for v in grub-mok-vars.fd sdboot-db-vars.fd; do
	if [ ! -r "$secboot_dir/$v" ]; then
		echo "missing: $secboot_dir/$v"
		need_vars=1
	fi
done
if [ "$need_vars" = 1 ]; then
	echo "SKIP: enrolled OVMF_VARS not present yet."
	echo "Generate locally (do not commit) — see vmtest/README-secboot.md"
	exit 0
fi

echo "ERROR: enrolled vars found but QEMU smoke runner not fully wired yet."
echo "CODE=$code"
echo "VARS ready:"
ls -la "$secboot_dir"/*.fd
echo "Next step: boot like run-in-container.sh with -drive if=pflash,format=raw,readonly=on,file=\$CODE"
echo "  and a writable copy of the enrolled VARS (q35 + SMM required for secboot)."
exit 1
