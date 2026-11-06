# Hardware

Machines where the firmware leaves the TSCs out of sync, and how tscsync
works on them. Please add yours with an issue (model, BIOS version, CPU,
distribution, and `tscsync-status` output).

## Tested with tscsync

| Model | CPU | BIOS | Pattern before boot | Result |
|---|---|---|---|---|
| Lenovo Legion Pro 5 16ADR10 / Legion R7000P ADR10 (83LT) | Ryzen 9 8945HX | RLCN32WW | BSP 5.0–6.5e9 cycles behind all 31 APs | TSC kept on every cold boot, reboot and S3 resume since v1.3; v2.0.0: BSP corrected to 0 cycles, 3 APs fine-tuned, verify 31/31 clean, 579 ms |
| Lenovo Legion Pro 5 16ADR10 | Ryzen 9 8940HX | RLCN32WW | BSP 4.8–5.0e9 cycles behind all 31 APs | v2.0.0 (Gentoo): verify 31/31 clean, 285 ms, TSC kept |
| Lenovo IdeaPad 5 2-in-1 14AHP9 | Ryzen 7 8845HS | P1CN32WW | BSP 3.76e9 cycles behind all 15 APs | v2.0.0: TSC kept; verify flagged 4 APs at -28..-42 cycles that the kernel accepted (slow round trips; reported as `UNSURE` since v2.1) |
| Lenovo Legion Pro 5 | Ryzen 9 8940HX | — | — (32 logical CPUs) | v2.1.0 `mode=sync`, driver loaded by rEFInd (then rEFInd → systemd-boot or a UKI): TSC kept; rEFInd showed a cosmetic yellow `ABORT`, fixed in v2.2 |
| Lenovo Legion 7 16ACHg6 (82N6) | Ryzen 9 5900HX | GKCN65WW | BSP 9.88e9 cycles (~3.0 s) behind all 15 APs, which agree within 26 cycles | v2.2.1 (AUR, Arch, GRUB): BSP corrected in 5 iterations, verify 15/15 clean, 157 ms, TSC kept; `clock_gettime` ~1320 ns → ~20 ns. Resume not tested |
| Lenovo Legion 5 gen 6 | Ryzen 5 5600H | — | — | v2.2.0/2.2.1 (Fedora): TSC lost after resume from deep sleep (S3), which tscsync cannot cover; see "Sleep" in the README |
| Lenovo ThinkPad E595 (20NF) | Ryzen 5 3500U | R11ET48P (1.28), R11ET50P (1.30) | BSP 6.2–9.9e9 cycles (~3 s) behind all 7 APs, 40 of 40 boots | v2.1.0: sync clean on every boot and the kernel's warp check passed. 1.28: TSC kept. 1.30: on 2 of 2 boots the clocksource watchdog then dropped the TSC for frequency skew (see "If Linux still drops the TSC" in the README); verify flagged warp-free APs at -34..+45 cycles that the kernel accepted |

## Reported with the same symptom (not yet tested with tscsync)

| Model | CPU | BIOS | Source |
|---|---|---|---|
| Lenovo Legion 5 (2021) | Ryzen | — | CachyOS forum |
| Lenovo IdeaPad 5 2-in-1 14AHP9 | Ryzen 7 8845HS | P1CN34WW (2026-03) | Lenovo forum: the newer BIOS still shows the warp |

## Fixed by the vendor in firmware

Lenovo fixed this class of bug by BIOS update on the ThinkPad A485 and T14s
Gen 1 (AMD). The E495 was listed here too, but it shares its BIOS package
with the E595, which still shows the warp on 1.30, the last release (see
above). If a BIOS update fixes your machine, tscsync's measure mode will show
every AP `OK` without sync.
