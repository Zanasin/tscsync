# Hardware

Machines where the firmware leaves the TSCs out of sync, and how tscsync
works on them. Please add yours with an issue (model, BIOS version, CPU,
distribution, and `tscsync-status` output).

## Tested with tscsync

| Model | CPU | BIOS | Pattern at GRUB | Result |
|---|---|---|---|---|
| Lenovo Legion Pro 5 16ADR10 / Legion R7000P ADR10 (83LT) | Ryzen 9 8945HX | RLCN32WW | BSP 5.0–6.5e9 cycles behind all 31 APs | TSC kept on every cold boot, reboot and S3 resume since v1.3; v2.0.0: BSP corrected to 0 cycles, 3 APs fine-tuned, verify 31/31 clean, 579 ms |

## Reported with the same symptom (not yet tested with tscsync)

| Model | CPU | BIOS | Source |
|---|---|---|---|
| Lenovo Legion Pro 5 16ADR10 | Ryzen 9 8940HX | RLCN32WW | Lenovo community forum, warp 4,813,071,762 cycles |
| Lenovo IdeaPad 5 2-in-1 14AHP9 | Ryzen 7 8845HS | P1CN32WW | Lenovo community forum, ~1 s warp |
| Lenovo Legion 5 (2021) | Ryzen | — | CachyOS forum |

## Fixed by the vendor in firmware

Lenovo fixed this class of bug by BIOS update on the ThinkPad A485, E495 and
T14s Gen 1 (AMD). If a BIOS update fixes your machine, tscsync's measure
mode will show every AP `OK` without sync.
