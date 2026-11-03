#!/usr/bin/bash
# SPDX-License-Identifier: MIT
# Test tscsync.efi in QEMU/OVMF VMs without installing anything on the host.
# Needs podman, /dev/kvm, and membership in the host kvm group. Builds first:
# make all test. Rootless podman drops supplementary groups unless given
# --group-add keep-groups, without which qemu cannot open /dev/kvm.
# The repository is mounted read-only; SELinux relabeling is disabled so the
# container cannot change any host file.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
podman=podman
[ -e /.flatpak-info ] && podman="flatpak-spawn --host podman"

make -C "$here" all test >/dev/null
$podman build -q -t localhost/tscsync-vmtest -f "$here/vmtest/Containerfile" "$here/vmtest"
$podman run --rm --device /dev/kvm --group-add keep-groups --security-opt label=disable \
	-v "$here:/work:ro" localhost/tscsync-vmtest bash /work/vmtest/run-in-container.sh
