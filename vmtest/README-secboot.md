# Opt-in Secure Boot smokes (Layer C)

Default `vmtest/run.sh` uses unsigned OVMF and does **not** exercise Secure Boot.

```sh
make vmtest-secboot
# or:
vmtest/run.sh --secure-boot
```

These smokes are optional and heavy. They are **not** part of the default VM suite or CI.

## What they do

`run-secboot.sh` boots **q35 + SMM** with `OVMF_CODE.secboot` and an enrolled varstore:

1. **systemd-boot + signed driver** — must print a `tscsync` banner and `RESULT:`
2. **systemd-boot + unsigned driver** — must fail with Access denied (negative control)
3. **GRUB + signed `tscsync.efi`** — same positive check, when `grub-mkstandalone` / `grub2-mkstandalone` is installed; otherwise skipped

By default the runner generates an **ephemeral** PK/KEK/db (openssl + `virt-fw-vars`), signs the bootloader and tscsync images with `sbsign`, and does not touch host Secure Boot keys. No sudo.

## Requirements

| Need | Typical package |
|---|---|
| `OVMF_CODE.secboot*.fd` | `edk2-ovmf` / `OVMF` |
| Matching empty `OVMF_VARS` template | same package |
| `qemu-system-x86_64`, `sbsign`, `virt-fw-vars`, `openssl`, `mtools`, `dosfstools` | qemu, sbsigntools, python-virt-firmware, … |
| `systemd-bootx64.efi` | systemd-boot / systemd |
| Optional: `grub-mkstandalone` + `grub-editenv` | grub |

Missing CODE → **SKIP** (exit 0). Missing required tools → hard error.

`/dev/kvm` is preferred (with `ICH9-LPC.disable_s3=1`, required for OVMF+SMM). If KVM produces no serial output, the runner retries once under TCG automatically.

## Optional: use your own enrolled vars

To exercise a specific key (for example the same certs you enrolled for host testing):

```sh
# write matching PEMs (gitignored) and enrolled varstores:
SEC=vmtest/secboot
# sign.key / sign.pem must match the db cert inside *-vars.fd
```

Or:

```sh
export TSCSYNC_SECBOOT_KEY=/path/to/db.key
export TSCSYNC_SECBOOT_CERT=/path/to/db.pem
# optional: pre-built $SEC/sdboot-db-vars.fd enrolled with that cert
make vmtest-secboot
```

### Finding CODE on common distros

`run-secboot.sh` searches several well-known paths, including:

- `/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd` (Arch `edk2-ovmf`, 4M images)
- `/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd` and similar Fedora layouts
- `/usr/share/OVMF/OVMF_CODE.secboot.fd`

If your package uses another path, write it to `vmtest/secboot/OVMF_CODE.secboot.path` (one line, absolute path). That file is local-only and gitignored via the `*.path` / `*.fd` rules under `secboot/`.

### Generating enrolled VARS (optional override)

```sh
SEC=vmtest/secboot
TEMPLATE=/path/to/OVMF_VARS.fd          # from the same OVMF package as CODE
CODE=/path/to/OVMF_CODE.secboot.fd
printf '%s\n' "$CODE" > "$SEC/OVMF_CODE.secboot.path"

virt-fw-vars \
  --input "$TEMPLATE" \
  --output "$SEC/sdboot-db-vars.fd" \
  --set-pk "$OWNER_GUID" /path/to/PK.pem \
  --add-kek "$OWNER_GUID" /path/to/KEK.pem \
  --add-db "$OWNER_GUID" /path/to/db.pem \
  --secure-boot

cp -a "$SEC/sdboot-db-vars.fd" "$SEC/grub-mok-vars.fd"
# also place the matching private key as $SEC/sign.key and cert as $SEC/sign.pem
```

Do **not** commit `*.fd`, `sign.key`, or `sign.pem`. Host firmware NVRAM and OVMF varstores are different; you cannot copy a machine’s live Secure Boot state into these files.

## Relationship to other tests

Installer policy (loader detect + signing key pick) does **not** need OVMF:

```sh
make check              # synthetic keys / mocked efivars
sudo make check-host    # optional read-only check against the machine’s real keys
```

## Packaging note

OVMF / QEMU Secure Boot packages are **developer** dependencies for this directory only. They should not be required (or listed as runtime optdepends) of distro packages that only install tscsync for the host boot path.
