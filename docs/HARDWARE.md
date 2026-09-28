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

## Reported with the same symptom (not yet tested with tscsync)

| Model | CPU | BIOS | Source |
|---|---|---|---|
| Lenovo Legion 5 (2021) | Ryzen | — | CachyOS forum |

## Fixed by the vendor in firmware

Lenovo fixed this class of bug by BIOS update on the ThinkPad A485, E495 and
T14s Gen 1 (AMD). If a BIOS update fixes your machine, tscsync's measure
mode will show every AP `OK` without sync.
