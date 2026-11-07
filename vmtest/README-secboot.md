# Opt-in Secure Boot smokes (Layer C)

Default `vmtest/run.sh` uses unsigned OVMF and does **not** exercise Secure Boot.

```sh
make vmtest-secboot
# or:
vmtest/run.sh --secure-boot
```

These smokes are optional and heavy. They are **not** part of the default VM suite or CI.

## Intended cases

When enrolled OVMF varstores are present under `vmtest/secboot/`:

1. **GRUB + enrolled signing key** — signed `tscsync.efi` must load under Secure Boot  
2. **systemd-boot + enrolled db key** — signed `tscsync-driver.efi` must load under Secure Boot  

Until the QEMU runner is fully wired, `make vmtest-secboot` either **SKIP**s (missing assets) or stops with a clear “not wired yet” message after locating CODE + VARS.

## Assets

| Asset | Role | Commit to git? |
|---|---|---|
| OVMF Secure Boot **CODE** firmware | QEMU pflash executable (`OVMF_CODE.secboot*.fd`) | **No** — use the distro package; optional local pointer file `OVMF_CODE.secboot.path` |
| Empty OVMF **VARS** template | Starting NVRAM image from the same package | **No** |
| `vmtest/secboot/*-vars.fd` | Enrolled varstores for the two smokes | **Never** — gitignored; may contain private PK/KEK/db material |

Host firmware Secure Boot state and QEMU’s OVMF varstore are different stores. You cannot copy a machine’s live NVRAM into these files. Rebuild trust inside the VM by enrolling certificates into a fresh template (see below).

### Finding CODE on common distros

`run-secboot.sh` searches several well-known paths, including:

- `/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd` (Arch `edk2-ovmf`, 4M images)
- `/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd` and similar Fedora layouts
- `/usr/share/OVMF/OVMF_CODE.secboot.fd`

If your package uses another path, write it to `vmtest/secboot/OVMF_CODE.secboot.path` (one line, absolute path). That file is local-only and gitignored via the `*.path` / `*.fd` rules under `secboot/`.

## Generating enrolled VARS

Requirements typically include:

- Distro OVMF Secure Boot firmware package (e.g. `edk2-ovmf`)
- A tool that can write EDK2 varstores (e.g. `virt-fw-vars` from `python-virt-firmware`, or `ovmf-vars-generator`)

Example with `virt-fw-vars` and your own PEM certificates (adjust paths and GUID):

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

# Until a dedicated MOK enrollment case exists, the same db enrollment can
# stand in for the GRUB smoke asset name:
cp -a "$SEC/sdboot-db-vars.fd" "$SEC/grub-mok-vars.fd"
```

For Microsoft/default test keys instead of your own, see `virt-fw-vars --enroll-microsoft` / `--enroll-redhat` and your distro’s `ovmf-vars-generator` documentation.

QEMU Secure Boot OVMF usually needs a **q35** machine with **SMM** enabled; copy the enrolled VARS to a writable temp file before each run (do not mutate the committed-local originals in place if you want them reusable).

## Relationship to other tests

Installer policy (loader detect + signing key pick) does **not** need OVMF:

```sh
make check              # synthetic keys / mocked efivars
sudo make check-host    # optional read-only check against the machine’s real keys
```

## Packaging note

OVMF / QEMU Secure Boot packages are **developer** dependencies for this directory only. They should not be required (or listed as runtime optdepends) of distro packages that only install tscsync for the host boot path.
