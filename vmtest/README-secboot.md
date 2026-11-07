# Opt-in Secure Boot smokes (Layer C)

Default `vmtest/run.sh` uses unsigned OVMF and does **not** exercise Secure Boot.

Heavy SB smokes (opt-in only):

```sh
make vmtest-secboot
# or:
vmtest/run.sh --secure-boot
```

Intended cases (when enrolled OVMF vars are present under `vmtest/secboot/`):

1. **GRUB + enrolled MOK** — signed `tscsync.efi` must load under SB  
2. **systemd-boot + enrolled db** — signed `tscsync-driver.efi` must load under SB  

These need `OVMF_CODE.secboot.fd` (Fedora `edk2-ovmf`) plus pre-built `OVMF_VARS` with keys enrolled. Generating those vars is interactive or tooling-specific; until `vmtest/secboot/*.fd` assets exist, `run.sh --secure-boot` **skips** with a clear message (exit 0) so default CI stays green.

Installer key-selection / loader-detect coverage lives in the fast suite:

```sh
make check   # scripts/test-install-policy.sh
```
