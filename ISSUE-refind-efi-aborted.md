## Summary

When `tscsyncx64.efi` is loaded as a **rEFInd** driver from `EFI/refind/drivers_x64/`, a successful sync still ends with a yellow **ABORT / failure** line in rEFInd’s UI, even though the on-screen report correctly ends with `RESULT: all APs in sync` and Linux keeps `clocksource: tsc`.

## Why it happens

As a boot-services driver, tscsync returns `EFI_ABORTED` on purpose so **systemd-boot** will unload it quietly (`src/tscsync.c`):

```c
BOOLEAN driver = li->ImageCodeType == EfiBootServicesCode;
EFI_STATUS done_status = driver ? EFI_ABORTED : EFI_SUCCESS;
```

rEFInd also loads `drivers_x64/*.efi` via `StartEFIImage(..., IsDriver=TRUE)`, but after `StartImage` it always calls `CheckError()` on the status. `EFI_ABORTED` is an `EFI_ERROR`, so rEFInd paints it yellow as “returned from tscsyncx64.efi … Aborted”. There is no `refind.conf` option to ignore that.

So: **cosmetic false failure under rEFInd; real sync is fine.** systemd-boot’s quiet-unload behaviour still wants `EFI_ABORTED`.

## Environment

- Host: Lenovo Legion Pro 5, Ryzen 9 8940HX (32 logical CPUs)
- tscsync 2.1.0, `mode=sync`
- Driver installed **only** under `EFI/refind/drivers_x64/` (not also under `EFI/systemd/drivers/`, to avoid a same-session double-load that trips the hang guard)
- Boot paths that work: rEFInd → UKI directly, and rEFInd → systemd-boot → UKI
- Hang guard / `tscsync-report.service` clear `pending` normally after Linux is up

## Request

**Preferred:** an **`options` token** so the driver can return `EFI_SUCCESS` under rEFInd without guessing the loader, e.g. in `\EFI\tscsync\options`:

```text
mode=sync exit=success
```

(or `loader=refind` / similar). Default remains `EFI_ABORTED` for systemd-boot’s quiet unload. This is portable for custom install paths and needs no device-path parsing.

**Also fine, as optional extras:**

1. Heuristic: if `LoadedImage.FilePath` contains `\EFI\refind\drivers`, default to `EFI_SUCCESS`; if `\EFI\systemd\drivers`, keep `EFI_ABORTED`.
2. Document that the yellow ABORT under rEFInd is expected when returning `EFI_ABORTED` with no override.

Happy to test a patch on this machine.

## References

- Design note on systemd-boot + `EFI_ABORTED`: `docs/DESIGN.md` (Boot integration)
- rEFInd `StartEFIImage`: always `CheckError` after `StartImage`, including for drivers
