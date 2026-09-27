# Secure Boot

With Secure Boot on, GRUB only runs EFI programs that are signed by a key the
firmware or shim trusts. tscsync is signed with a Machine Owner Key (MOK),
the same kind of key used for out-of-tree kernel modules such as NVIDIA's.

## If you already have a MOK

`scripts/install.sh` looks for keys that distributions already create for
kernel modules and uses the first one it finds:

| Distribution | Key | Certificate |
|---|---|---|
| Fedora (akmods) | `/etc/pki/akmods/private/private_key.priv` | `/etc/pki/akmods/certs/public_key.der` |
| Ubuntu / Debian (DKMS, newer) | `/var/lib/dkms/mok.key` | `/var/lib/dkms/mok.pub` |
| Ubuntu / Debian (shim-signed) | `/var/lib/shim-signed/mok/MOK.priv` | `/var/lib/shim-signed/mok/MOK.der` |

It checks that the certificate is actually enrolled (by fingerprint, via
`mokutil --list-enrolled`) before installing. To use another key:

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

```sh
sudo scripts/install.sh --no-sign
sudo sbctl sign -s /boot/efi/EFI/tscsync/tscsync.efi    # adjust the ESP path
```

## If GRUB refuses the tool

`tscsync-status` then reports "tscsync.efi did not run on this boot", and the
boot itself continues normally. Check that the key is enrolled
(`mokutil --list-enrolled`) and reinstall.
