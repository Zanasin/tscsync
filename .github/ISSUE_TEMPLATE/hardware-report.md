---
name: Hardware report
about: Report whether tscsync works on your machine
title: "[hardware] <vendor> <model>"
---

**Model and machine type:**
**BIOS version and date:** (`cat /sys/class/dmi/id/bios_version /sys/class/dmi/id/bios_date`)
**CPU:** (`grep -m1 'model name' /proc/cpuinfo`)
**Distribution and kernel:**
**Secure Boot:** on / off

**Warp before tscsync:** (`journalctl -k -b | grep -i 'TSC warp'`)

**`tscsync-status` in measure mode:**
```
```

**`tscsync-status` in sync mode (if tried):**
```
```

**Result:** kept TSC / fell back to HPET / other
