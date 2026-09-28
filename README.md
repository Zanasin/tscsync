# tscsync

Fixes "TSC warp between CPUs" on AMD machines before Linux boots, so the
kernel keeps the fast TSC clocksource instead of falling back to HPET.

```
tsc: Marking TSC unstable due to check_tsc_sync_source failed
clocksource: Switched to clocksource hpet
```

If your kernel log shows those lines on every boot, your firmware (BIOS) is
handing over with the CPU cores' Time Stamp Counters out of sync. tscsync is a
small UEFI program that runs from the boot loader (GRUB or systemd-boot)
just before Linux, measures every
core's TSC, moves the lagging ones forward until they agree, and then checks
the result with a test modelled on the kernel's own.

On a Legion Pro 5 16ADR10 this turned a 5.2-billion-cycle warp (about 2 s) on
every boot into cores that agree to within about ±10 cycles, and Linux kept
the TSC on every cold boot, reboot and resume from sleep.

## Do I need it?

Check the current boot:

```sh
journalctl -k -b | grep -iE 'TSC warp|TSC unstable'
cat /sys/devices/system/clocksource/clocksource0/current_clocksource
```

You are affected if the first command prints `Measured N cycles TSC warp
between CPUs` and the second prints `hpet`. tscsync is designed for:

- AMD Zen (families 17h, 19h, 1Ah) and Hygon (18h) CPUs. They have no
  `IA32_TSC_ADJUST`, so the kernel cannot repair the offset itself.
- Laptops and desktops of any brand whose firmware leaves the TSCs unsynced.
  Reported so far on Lenovo Legion and IdeaPad models; see
  [docs/HARDWARE.md](docs/HARDWARE.md).

You do **not** need it on Intel CPUs with `TSC_ADJUST` (the kernel fixes
those itself), and it cannot help if the warp is caused by something other
than the boot-time offset.

## Why bother

With HPET, every clock read goes to a slow timer chip (about 1.2 µs instead of
tens of nanoseconds). The kernel and desktop read the clock tens of thousands
of times a second, which costs latency and power. On the Legion, idle CPU
temperature dropped from 66–72 °C to 59–63 °C after the fix.

Forcing the TSC with `tsc=reliable` does not work: the cores really are out of
sync, which causes audio and video stutter. The out-of-tree `tsc=directsync`
kernel patch tries to fix it in the kernel but was rejected upstream. tscsync
fixes the offset before the kernel starts, so the kernel's own safety checks
stay on and confirm the result.

## How it works

1. GRUB runs `tscsync.efi` before showing its menu; systemd-boot loads the
   same code as a driver (`EFI/systemd/drivers/tscsyncx64.efi`) before its
   menu.
2. It asks every core for its TSC through the firmware's MP services and
   measures each core's offset against the boot processor (BSP).
3. In sync mode it moves counters **forward only**: the BSP catches up to the
   other cores if they are ahead, then every core still lagging catches up to
   the BSP. It repeats until each core is within about 10 cycles.
4. It verifies every core with a lock-and-compare test like the kernel's
   `check_tsc_warp()`, stores a report in RAM, and returns to the boot loader.
5. Linux boots, finds the TSCs in sync and keeps the TSC clocksource.

The whole run takes about 0.6 s. Details and measurements:
[docs/DESIGN.md](docs/DESIGN.md).

## Safety

- It never writes flash, NVRAM or firmware settings. The TSC registers it
  changes reset at power-off, and its report is a RAM-only EFI variable. Its
  only disk writes are its own hang-guard flag: in grubenv with GRUB, or small
  files in `EFI/tscsync/` on the EFI system partition with systemd-boot.
- `install.sh` starts in read-only measure mode. You switch to sync only after
  you've seen the numbers.
- Large corrections only move counters forward. Backward steps are capped at
  1 million cycles (about 0.4 ms) and only used for fine-tuning.
- If a boot never reaches Linux, the next boot skips tscsync and turns it off
  (the hang guard). Booting another OS from the boot menu counts too; run
  `sudo scripts/set-mode.sh sync` to turn it back on.
- Secure Boot stays on. The binary is signed with a Machine Owner Key (MOK)
  you already have or create once, or with systemd-boot, a key in the
  firmware's db such as sbctl's.
- If anything goes wrong, Linux falls back to HPET, the same as it would
  without tscsync.
- In sync mode it refuses unfamiliar hardware (CPUs with `TSC_ADJUST`, without
  an invariant TSC, or outside the supported list) unless you opt in.

This is unofficial, low-level software. Read the code and use it at your own
risk; the MIT license applies.

## Requirements

- x86_64 UEFI system booting Linux with **GRUB** or **systemd-boot**
- GRUB: its config directory on ext2/3/4 or FAT (needed for the hang guard)
- systemd-boot: nothing extra; the settings and the hang guard are small
  files in `EFI/tscsync/` on the EFI system partition
- systemd
- Build tools: `gcc`, `make`, `binutils`, `curl`
- With Secure Boot: `sbsigntools` and an enrolled MOK, or your own `sbctl`
  keys
  ([docs/SECURE-BOOT.md](docs/SECURE-BOOT.md))

## Quick start

```sh
git clone https://github.com/Zanasin/tscsync.git
cd tscsync
make                               # downloads and verifies gnu-efi, builds the GRUB and systemd-boot binaries
sudo scripts/install.sh            # installs in read-only measure mode
```

Shut down fully, power on, then:

```sh
tscsync-status
```

If the report shows cores out of sync (`BAD` lines in the survey), switch to
sync mode and reboot:

```sh
sudo scripts/set-mode.sh sync
```

Success looks like this in `tscsync-status`:

```
current clocksource : tsc
...
  RESULT: all APs in sync (Linux should keep the TSC)
```

A core marked `UNSURE` passed the warp test, but its offset reading was taken
over a slower round trip than usual, so tscsync cannot tell whether it is in
sync. The kernel's own check decides: if `current clocksource` is `tsc`, it
passed.

## Commands

| Command | What it does |
|---|---|
| `sudo scripts/install.sh` | Detects GRUB or systemd-boot, the EFI partition and a signing key, installs in measure mode |
| `sudo scripts/set-mode.sh measure\|sync\|off` | Switches mode for the next boot |
| `tscsync-status` | Clocksource, kernel TSC messages, and this boot's tscsync report |
| `sudo scripts/uninstall.sh` | Removes everything |
| `build/tscprobe` | Live per-core TSC offsets from Linux (read-only) |
| `sudo tools/idle-bench.sh 300` | Idle temperature, sleep states and CPU power, for before/after comparisons |
| `vmtest/run.sh` | Runs the test suite in QEMU/OVMF VMs via podman |

## Recovery

- If a boot hangs in tscsync (the text stops for 30 s), hold power for 10 s
  and power on again. The hang guard skips tscsync and disables it.
- For anything else odd, run `sudo scripts/set-mode.sh off` or
  `sudo scripts/uninstall.sh`.
- If the boot loader itself becomes unusable (it shouldn't), boot a live USB
  and mount the partition holding the files. GRUB: delete `custom.cfg` in
  GRUB's config directory. systemd-boot: delete
  `EFI/systemd/drivers/tscsyncx64.efi` on the EFI system partition.

## After a BIOS update

Your vendor may fix the firmware. Run `sudo scripts/set-mode.sh measure` and
reboot: if every core reports `OK` without sync mode, you can uninstall
tscsync.

## Report your hardware

Whether it works or not, please open an issue with your model, BIOS version,
CPU and the output of `tscsync-status`. That builds the list in
[docs/HARDWARE.md](docs/HARDWARE.md) and shows vendors how widespread the bug
is.

## Background report

[docs/report/tsc-firmware-report.pdf](docs/report/tsc-firmware-report.pdf)
covers 80 boots of boot history from the Legion Pro 5. It explains why this
BIOS leaves the TSCs out of sync when the hardware can keep them in sync, and
makes the case for open firmware with safe, vendor-signed updates. The data
and scripts behind it are in [docs/report/](docs/report/).

## License

MIT, see [LICENSE](LICENSE). Firmware vendors are welcome to use the approach
or the code in their own firmware, which is where this should be fixed. The
report in `docs/report/` is under CC BY 4.0.

gnu-efi, downloaded at build time, is under its own BSD-style license.
