#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Test tscsync.efi in QEMU/OVMF VMs without installing anything on the host.
# Needs podman and /dev/kvm. Builds first: make all test.
# Where /dev/kvm is not open to everyone (often 0660 root:kvm), it also needs
# membership in the host kvm group, and rootless podman then gets
# --group-add keep-groups (crun only), without which qemu cannot open it.
# The repository is mounted read-only; SELinux relabeling is disabled so the
# container cannot change any host file.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
host=
[ -e /.flatpak-info ] && host="flatpak-spawn --host"
podman="$host podman"
keep_groups=
case $($host stat -c %a /dev/kvm 2>/dev/null || echo 0) in
*[67]) ;;	# rw for everyone: no group needed
*) keep_groups="--group-add keep-groups" ;;
esac

make -C "$here" all test >/dev/null
$podman build -q -t localhost/tscsync-vmtest -f "$here/vmtest/Containerfile" "$here/vmtest"
$podman run --rm --device /dev/kvm $keep_groups --security-opt label=disable \
	-v "$here:/work:ro" localhost/tscsync-vmtest bash /work/vmtest/run-in-container.sh
