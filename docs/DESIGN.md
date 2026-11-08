# Design

## The problem

Every x86 core has a Time Stamp Counter (TSC). Linux uses it as its main
clock only if all cores agree. At boot, `check_tsc_sync_source()` compares
each application processor (AP) with the boot processor (BSP); if any core
ever reads a value lower than one another core read just before, it reports

```
Measured N cycles TSC warp between CPUs, turning off TSC clock.
```

and switches to HPET. On Intel CPUs with `IA32_TSC_ADJUST` the kernel can
correct small offsets itself. AMD Zen CPUs do not have `TSC_ADJUST`, so if the
firmware leaves the counters out of sync, nothing in Linux can fix it; the
kernel maintainers rejected an in-kernel TSC-write approach (`tsc=directsync`)
as unreliable. Windows writes the TSCs itself at boot, which is why such
firmware bugs go unnoticed in vendor testing.

## Case study: Legion Pro 5 16ADR10 (BIOS RLCN32WW, Ryzen 9 8945HX)

Measured on the machine that motivated this project:

- All 71 boots with a complete kernel log showed a warp.
- The warp is proportional to time spent in firmware. Across 62 boots,
  warp = 833.29 M cycles per second of FPDT `bootloader_launch` time
  (R² = 0.999999, intercept −0.4 ms). FPDT time is measured with the BSP's
  TSC, so at loader launch the BSP's TSC read 3/4 of the APs'. That's a scale
  error; a fixed delay would give the same warp on every boot.
- Measured from GRUB, all 31 APs agreed with each other within ~40 cycles
  across both CCDs, and all were 5.2–5.7 billion cycles ahead of the BSP. Only
  the BSP is off.
- The offsets survive into Linux unchanged, so fixing them in GRUB is enough.
- The S3 resume path is fine: after resume all cores agree, and the kernel's
  re-check passes.

## Algorithm

tscsync runs from the boot loader before its menu: as a UEFI application
launched by GRUB, or as a boot-services driver loaded by systemd-boot or rEFInd (see
Boot integration).

### Measuring an offset

For each AP, tscsync starts a responder on it with
`EFI_MP_SERVICES_PROTOCOL.StartupThisAP` (non-blocking). The BSP then does
4000 ping-pong rounds through a shared cache line:

```
BSP: t0 = rdtscp; req = n      AP: sees req; a = rdtscp; ack = n
BSP: sees ack; t1 = rdtscp
offset = a - (t0 + t1) / 2
```

It keeps the rounds with the smallest round trip and averages their offsets,
which resolves offsets finer than one TSC tick. Interrupts are masked on the
BSP (TPL_HIGH_LEVEL) while measuring.

The formula assumes both legs of a round trip take equally long. When one leg
is delayed, the estimate is skewed by up to half the extra delay. On an
IdeaPad 5 2-in-1 14AHP9 the same APs read 0 to 8 cycles at a round trip of
~340 cycles, and -28 to -42 at ~500–530 cycles, with no write in between;
the kernel accepted them. So read-only passes re-measure an offset that is
outside the limit but no larger than one round trip (up to 4 times) and keep
the fastest round trip. If it is still outside the limit, the warp test is
clean, and the round trip was slower than the fastest one seen for that AP
this boot by at least twice the offset, the AP is reported as `UNSURE`
rather than `BAD`: tscsync cannot tell, and the kernel's check decides.

An AP that is still past the limit but warp-free stays `BAD`, marked
`(past the limit, no warps)`, and when every failure is like that the
`RESULT` line no longer promises an HPET fallback. Neither the offset nor the
round trip predicts the kernel's verdict here: on the 16ADR10 the kernel
rejected APs at +38..+51 cycles with round trips of 200–850 cycles, while on
a ThinkPad E595 it accepted -34..+45 at 300–500 cycles. A looser limit such
as half the round trip would have passed the 16ADR10 case. Only warps the
test sees mean a sure fallback.

### Correcting

Writes use `wrmsr(0x10, rdtsc() + delta)` right after a TSC tick edge, so the
delay between read and write lands at a consistent phase. The write lands
slightly short of its target; the loop learns that shortfall and compensates
on the next write, ignoring implausible values (over 5000 cycles, e.g. from
an interrupt between read and write).

Strategy, all moves forward:

1. Survey every AP (read-only).
2. If any AP is ahead of the BSP, move the BSP forward: to the median AP when
   all APs are ahead and agree within 1 M cycles (the BSP lands mid-cluster,
   so usually no AP needs a write), otherwise to the furthest-ahead AP.
3. Move every AP that still lags forward to the BSP. A corrected AP is only
   accepted when its offset is in range **and** the warp test below is clean;
   otherwise it is nudged a few cycles in the direction the test points.
4. Verify every AP.

### Verifying

For each AP, tscsync measures the offset again and runs a warp test modelled
on the kernel's `check_tsc_warp()`: BSP and AP take strict turns reading the
TSC and comparing it with the other core's previous read, 20,000 times.
Strict alternation makes every comparison cross-core, so it is at least as
sensitive as the kernel's spinlock-based test.

### Thresholds, and where they come from

| Constant | Value | Reason |
|---|---|---|
| `TOLERANCE` | 10 cycles | Correction target. On real hardware the kernel accepted APs within ±18 cycles of the BSP and rejected +38..+51. |
| `VERIFY_LIMIT` | 25 cycles | Verify-pass limit; absorbs pass-to-pass measurement noise without passing a real warp. |
| `ACT_THRESHOLD` | 200 cycles | Survey offsets below this are treated as noise. |
| `MAX_BACKWARD` | 1,000,000 cycles | Largest backward step (fine-tuning only). |
| `MAX_FORWARD` | 1.5e11 cycles | Largest forward step (~60 s at 2.5 GHz); larger offsets are treated as implausible. |
| `WARP_ITERS` | 20,000 | Warp-test rounds per AP in the verify pass; about 13 ms per AP. |
| `WARP_GATE_ITERS` | 20,000 | Warp-test rounds when accepting a corrected core. A shorter gate saves ~10 ms per corrected core but gives up margin; kept at full length. |

If the TSC reads in coarse ticks at firmware time (detected at start), a core
counts as in sync only at an exact zero-tick offset.

### Boot cost

About 0.6 s on a 32-thread Ryzen (v2.0.0 measured 579 ms): survey ~35 ms,
BSP correction ~60–100 ms, AP pass ~60 ms, verify with warp tests ~400 ms.
`systemd-analyze` reports a longer "loader" time because the firmware
measures it with the BSP's TSC, which tscsync moves forward.

## Boot integration

- GRUB's stock `41_custom` script makes `grub.cfg` source
  `<grub dir>/custom.cfg` before the menu is shown. tscsync installs its hook
  there, so `grub.cfg` is never regenerated or edited.
- The hook chainloads `EFI/tscsync/tscsync.efi` with the mode as load options.
  When it returns, GRUB continues normally.
- Hang guard: the hook sets `tscsync_pending=1` in grubenv before running
  the tool; `tscsync-report.service` clears it once Linux is up. A boot that
  never reaches Linux leaves it set, so the next boot skips the tool and sets
  `tscsync_enable=0`. The service is wanted by both `multi-user.target` and
  `system-update.target`: offline-update boots (PackageKit, dnf offline)
  never reach `multi-user.target`, and without this, one such boot was
  enough to disable tscsync. `install.sh` sets `RequiresMountsFor=` on the
  unit to the filesystem that holds the hang guard (grubenv for GRUB, or
  the ESP for systemd-boot / rEFInd) so a separate ESP mount such as
  `/boot/efi` is ready before the clear runs.
- systemd-boot has no hook like `custom.cfg`, but before its menu it loads
  every `\EFI\systemd\drivers\*x64.efi` that is a boot-services driver, and
  unloads one that returns `EFI_ABORTED` without logging an error. The same
  code is built as such a driver (`build/tscsync-driver.efi`, installed as
  `tscsyncx64.efi`); it detects that it was loaded as a driver and returns
  `EFI_ABORTED` by default. rEFInd loads the same binary from
  `drivers_x64` in its own folder (`EFI/refind` or `EFI/BOOT`, found by its
  `refind.conf`; detected from the firmware's `BootCurrent` entry, since
  rEFInd sets no variable of its own), but shows `EFI_ABORTED` as a yellow
  error after a successful run, so `exit=success` in the options returns
  `EFI_SUCCESS` instead; the installer sets it for rEFInd. The image then
  stays loaded until `ExitBootServices`, which is harmless. State
  is three small files in `\EFI\tscsync` on the same ESP: `options`,
  `disabled` (`set-mode.sh off`, or the hang guard) and `pending` (the hang
  guard: created before any work, deleted by `tscsync-report.service`; found
  at the next boot, it creates `disabled`). If `pending` cannot be written,
  the driver does nothing.
- Two copies in one boot: rEFInd chaining to systemd-boot, for example, would
  start the driver twice, and the second copy would find the first one's
  `pending` file and switch tscsync off. So before anything else, every copy
  checks for the result variable below; it is volatile, so it exists only if
  tscsync already ran since the last reset. Then the copy returns at once,
  leaving the first run's result and hang guard alone.
- The report is stored in the volatile EFI variable
  `TscSyncResult-950a48f2-b67d-4798-a024-88b7bf386000` and copied to
  `/run/tscsync-result.txt` at boot.

## Testing

`vmtest/run.sh` boots GRUB and tscsync, then systemd-boot and the tscsync
driver, in QEMU/OVMF VMs (8 vCPUs) inside a podman container, using the real
`custom.cfg` hook and systemd-boot's own driver loading. Where `/dev/kvm` is
not open to everyone, rootless podman is passed `--group-add keep-groups`
(crun only) so the host `kvm` group still applies when opening it:

- release build in measure mode, and in sync mode where sync must be refused;
- test build (`make test`) that first creates a warp, in three patterns:
  BSP behind all APs, APs behind the BSP, and mixed;
- the hang guard, for both boot loaders, and the systemd-boot state files;
- the driver's exit status as rEFInd sees it (the UEFI shell's `load` reports
  it the same way), with and without `exit=success`;
- two copies in one boot (shell-loaded copy, then systemd-boot's): only the
  first runs.

KVM's TSC writes jitter by 50–200 cycles, so the test build uses looser
tolerances (±50-cycle target, 30 iterations); with a looser ±100 target,
cores parked near the edge occasionally failed verify. Final precision can
only be confirmed on real hardware. Guest TSC
behaviour in KVM is also only faithful when the host's own TSC is stable.

## Version history

| Version | Change |
|---|---|
| 1.0 | Read-only measure mode, GRUB hook, hang guard |
| 1.1 | Sync by moving APs forward (wrong direction for the Legion: its BSP lags) |
| 1.2 | Move the BSP forward; tick-aware measurement; warp test |
| 1.3 | ±10-cycle target, median AP reference, strictly alternating warp test |
| 1.4 | Separate verify limit (±25) to stop false "out of sync" reports |
| 1.5 | ~0.5 s boot cost instead of ~5 s; plausibility filter on the landing-error estimate |
| 2.0 | General release: any warp pattern (forward-only), AMD/Hygon Zen families, distro-independent installer, warp-test gate on AP corrections |
| 2.1 | systemd-boot support (driver build, state files on the ESP); re-measure small misses in read-only passes and report `UNSURE` instead of `BAD` when the offset is within the measurement error; hang guard also cleared on offline-update boots |
| 2.2 | rEFInd support (installer detects it from `BootCurrent`, driver in rEFInd's `drivers_x64`, `exit=success` so rEFInd shows no error); a second copy in the same boot returns at once instead of tripping the hang guard; `tscsync-status` says whether the warp check or the clocksource watchdog dropped the TSC; warp-free misses no longer promise an HPET fallback |
| 2.2.1 | Reinstalling keeps the current mode (`--measure` to reset); the hang-guard service waits for the mount that holds the guard, e.g. a separate `/boot/efi` (#5); vmtest keeps the `kvm` group only where `/dev/kvm` needs it |
| 2.2.2 | With Secure Boot off, a signing key found on the system no longer makes `sbsign` mandatory (installs unsigned if it is missing, #7); README notes on sleep (tscsync can't run on S3 resume, #8) and the AUR package |
| (unreleased) | Installer: evidence-based loader detect (then grub.cfg, then a rEFInd install; systemd-boot only from LoaderInfo); auto-sign only with an enrolled/trusted key (skip leftover DKMS); rEFInd/systemd-boot prefer sbctl db; `make check` policy tests; opt-in `make vmtest-secboot` (q35+SMM OVMF smokes) |
