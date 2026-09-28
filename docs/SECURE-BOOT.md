# Secure Boot

With Secure Boot on, the boot loader only runs EFI programs that are signed
by a key the firmware or shim trusts. With GRUB, tscsync is usually signed
with a Machine Owner Key (MOK), the same kind of key used for out-of-tree
kernel modules such as NVIDIA's. With systemd-boot, see the section below.

## If you already have a MOK

`scripts/install.sh` looks for keys that distributions already create for
kernel modules and uses the first one it finds:

| Distribution | Key | Certificate |
|---|---|---|
| Fedora (akmods) | `/etc/pki/akmods/private/private_key.priv` | `/etc/pki/akmods/certs/public_key.der` |
| Ubuntu / Debian (DKMS, newer) | `/var/lib/dkms/mok.key` | `/var/lib/dkms/mok.pub` |
| Ubuntu / Debian (shim-signed) | `/var/lib/shim-signed/mok/MOK.priv` | `/var/lib/shim-signed/mok/MOK.der` |

It also finds `sbctl`'s db key (`/var/lib/sbctl/keys/db/db.key`). It checks
that the certificate is actually enrolled (by fingerprint, as a MOK via
`mokutil --list-enrolled`, or in the firmware's db via `mokutil --db`) before
installing. To use another key:

```sh
sudo scripts/install.sh --key /path/to/key.pem --cert /path/to/cert.der
```

## Creating and enrolling a MOK

```sh
openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 -subj "/CN=tscsync local signing key/" \
    -keyout tscsync-mok.key -outform DER -out tscsync-mok.der
sudo install -D -m 0600 tscsync-mok.key /root/tscsync-mok/tscsync-mok.key
sudo install -D -m 0644 tscsync-mok.der /root/tscsync-mok/tscsync-mok.der
sudo mokutil --import /root/tscsync-mok/tscsync-mok.der    # choose a one-time password
```

Reboot. The blue MokManager screen appears: choose **Enroll MOK**, confirm,
and enter the one-time password. Then:

```sh
sudo scripts/install.sh --key /root/tscsync-mok/tscsync-mok.key --cert /root/tscsync-mok/tscsync-mok.der
```

Keep the private key readable only by root: anything signed with it will run
at boot on this machine.

## sbctl (own platform keys, no shim)

If you manage your own Secure Boot keys with `sbctl`, GRUB checks images
against the firmware's `db` instead of MOKs. Install unsigned, then sign the
installed file with sbctl:

The installer finds sbctl's key and signs with it. To sign yourself instead:

```sh
sudo scripts/install.sh --no-sign
sudo sbctl sign -s /boot/efi/EFI/tscsync/tscsync.efi         # GRUB (adjust the ESP path)
sudo sbctl sign -s /efi/EFI/systemd/drivers/tscsyncx64.efi   # systemd-boot
```

## systemd-boot

systemd-boot loads drivers with the firmware's `LoadImage`, which checks the
firmware's `db`. A key in `db` (for example from `sbctl`) always works. A
MOK-only key works only where shim verifies the image, which may not be the
case; then systemd-boot skips tscsync and boots normally.

## If the boot loader refuses the tool

`tscsync-status` then reports "tscsync.efi did not run on this boot", and the
boot itself continues normally. Check that the key is enrolled
(`mokutil --list-enrolled`) and reinstall.
