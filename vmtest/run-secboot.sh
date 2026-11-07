#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Opt-in Secure Boot OVMF smokes. Not run by default (heavy / needs enrolled vars).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
secboot_dir=$here/vmtest/secboot

echo "== tscsync Secure Boot smokes (opt-in) =="
echo "Assets directory: $secboot_dir"

code=
for c in /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd \
	/usr/share/OVMF/OVMF_CODE.secboot.fd \
	/usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.fd; do
	[ -r "$c" ] && { code=$c; break; }
done
if [ -z "$code" ]; then
	echo "SKIP: no OVMF_CODE.secboot.fd on this host (install edk2-ovmf / OVMF secboot)."
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
	echo "Add grub-mok-vars.fd and sdboot-db-vars.fd under vmtest/secboot/ (see README-secboot.md),"
	echo "then re-run: make vmtest-secboot"
	exit 0
fi

echo "ERROR: enrolled vars found but smoke runner not fully wired in this tree yet."
echo "Vars are ready for a follow-up that boots QEMU like run-in-container.sh with -drive if=pflash secboot."
exit 1
