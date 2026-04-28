# Exynos8890 OneUI: Targeted Optimization Plan (Pageboost-only full backport)

This plan follows the constraint:
- **Full backport only for Pageboost** (from Exynos9810 tree model).
- All other items are done using defconfig, tunables, or small hooks in existing drivers.

## 1) Pageboost backport (full)

Status in this tree:
- Driver path: `drivers/staging/samsung/pageboost.c`
- Kconfig symbols: `CONFIG_SAMSUNG_PAGEBOOST`, `CONFIG_PAGEBOOST_IO_BOOST`, `CONFIG_PAGEBOOST_DEBUG`
- Sysfs controls: `/sys/kernel/pageboost/pageboost_active`, `/sys/kernel/pageboost/pageboost_record`

Build wiring:
- `drivers/staging/samsung/Kconfig`
- `drivers/staging/samsung/Makefile`

Required defconfig flags:
```config
CONFIG_SAMSUNG_PAGEBOOST=y
CONFIG_PAGEBOOST_IO_BOOST=y
# CONFIG_PAGEBOOST_DEBUG is not set
```

Recommended runtime tuning (init script):
```sh
# keep page recorder on, but disable verbose logging
echo 1 > /sys/kernel/pageboost/pageboost_active
echo 1 > /sys/kernel/pageboost/pageboost_record

# OneUI memory profile
echo 180 > /proc/sys/vm/swappiness
echo 40  > /proc/sys/vm/vfs_cache_pressure
```

## 2) SchedTune / EAS tuning (no subsystem backport)

Use existing framework and tune cgroups from userspace:

```sh
# top-app: max UI priority
echo 50 > /dev/stune/top-app/schedtune.boost
echo 1  > /dev/stune/top-app/schedtune.prefer_idle

# foreground: balanced
echo 15 > /dev/stune/foreground/schedtune.boost
echo 1  > /dev/stune/foreground/schedtune.prefer_idle

# background: keep cool
echo 0 > /dev/stune/background/schedtune.boost
```

Core control / big cluster recommendations:
```sh
# keep big cores available for unlock/UI bursts
echo 4 > /sys/devices/system/cpu/core_ctl/min_cpus
echo 4 > /sys/devices/system/cpu/core_ctl/max_cpus
```

## 3) Defconfig raw-performance block

Reference fragment: `arch/arm64/configs/exynos8890_hero_defconfig.fragment`

```config
CONFIG_SCHED_TUNE=y
CONFIG_SCHED_WALT=y
CONFIG_CPU_FREQ_GOV_INTERACTIVE=y
CONFIG_HOTPLUG_CPU=y

CONFIG_SAMSUNG_PAGEBOOST=y
CONFIG_PAGEBOOST_IO_BOOST=y
CONFIG_ZRAM=y
CONFIG_ZRAM_LZ4_COMPRESS=y
CONFIG_CMA=y
CONFIG_CMA_SIZE_SEL_MBYTES=y
CONFIG_CMA_SIZE_MBYTES=128

# Debug overhead removal
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_DEBUG_SPINLOCK is not set
# CONFIG_LOCKDEP is not set
# CONFIG_SCHED_DEBUG is not set
# CONFIG_FTRACE is not set
# CONFIG_KPROBES is not set
# CONFIG_PROFILING is not set
# CONFIG_SEC_DEBUG is not set

# Responsiveness
CONFIG_HZ_300=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_RCU_BOOST=y
CONFIG_RCU_FANOUT=32
```

## 4) Fingerprint 4-core max boost (minor hook)

Implemented in `drivers/cpufreq/cpufreq_interactive.c`:
- Added module parameter: `fingerprint_boost_4core_max` (default `true`)
- When fingerprint boost triggers:
  - big policy (cpu4+) goes to `policy->max`
  - little policy is skipped while this mode is enabled

Runtime controls:
```sh
# keep 4-core max lock behavior on
echo 1 > /sys/module/cpufreq_interactive/parameters/fingerprint_boost_4core_max
# tune pulse window
echo 160000 > /sys/module/cpufreq_interactive/parameters/fingerprint_boost_duration
```

## 5) Existing driver optimization (minor/no-backport)

Recommended safe knobs:

```sh
# Binder IPC latency profile
echo 1 > /sys/module/binder/parameters/stop_on_user_error 2>/dev/null || true

# Block queue (UFS)
for q in /sys/block/sd*/queue; do
  echo 2 > "$q"/nr_requests 2>/dev/null || true
  echo 0 > "$q"/iostats 2>/dev/null || true
done

# F2FS (if userdata uses f2fs): prefer inline and reduced checkpoint pressure at mount
# Example fstab flags: inline_xattr,inline_data,flush_merge,background_gc=on
```

## 6) Audio boost (+3dB to +5dB) using existing path

Do not backport new audio stacks. Apply only small gain table adjustment in existing codec path.

Recommended implementation style:
- Add a Kconfig guard: `CONFIG_SND_SOC_EXYNOS_SAFE_GAIN_BOOST`
- Increase DAC digital gain limit by one step (roughly +3dB) first.
- Keep a hard cap to avoid clipping in speaker path.

Pseudo-diff target (example style):
```diff
- #define EXYNOS_DAC_GAIN_MAX 0x5A
+ #define EXYNOS_DAC_GAIN_MAX 0x5E  /* ~+3dB class increase */
```

Validation checklist:
- pink noise test for clipping at 90-100% volume
- speaker thermal test (5 min)
- headset THD check with high gain disabled by default

## Implementation order

1. Enable Pageboost + IO boost in defconfig.
2. Apply fingerprint 4-core boost hook.
3. Apply defconfig cleanup and responsiveness block.
4. Push runtime stune/core_ctl/vm settings from init script.
5. Add conservative audio gain step (+3dB), validate, then optionally +5dB.
