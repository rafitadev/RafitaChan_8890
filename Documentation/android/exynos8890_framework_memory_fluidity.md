# Exynos8890 Framework + Memory Fluidity Patchset (One UI)

## Patches (C code)

### 1) SurfaceFlinger kernel boost hook (sched boost trigger)

File: `drivers/cpufreq/cpufreq_interactive.c`

```diff
+static unsigned int surfaceflinger_boost_duration = 120000;
+module_param(surfaceflinger_boost_duration, uint, 0644);
+
+static int set_surfaceflinger_boostpulse(const char *val,
+                const struct kernel_param *kp)
+{
+        ...
+        if (trigger) {
+                unsigned int orig = fingerprint_boost_duration;
+                fingerprint_boost_duration = surfaceflinger_boost_duration;
+                cpufreq_interactive_fingerprint_boostpulse();
+                fingerprint_boost_duration = orig;
+        }
+        return 0;
+}
+
+module_param_cb(surfaceflinger_boostpulse, ...);
```

How to use from userspace:
```sh
# Trigger boost on app launch/animation start
# (call from SurfaceFlinger/perf daemon hook)
echo 1 > /sys/module/cpufreq_interactive/parameters/surfaceflinger_boostpulse
```

### 2) Memory latency policy for OneUI (safe path)

For this 3.18 Exynos8890 tree, **do not full-backport new vmalloc/vmmalloc allocator internals** from 9810,
because this branch has known instability risk with those deep MM changes.

Use the stable low-latency memory path already integrated:
- Pageboost prefetch/record,
- swappiness/vfs tuning,
- ZRAM + ZSWAP,
- kswapd throttle controls.

### 3) S-Boost 2.0 behavior

Use combined triggers:
- input boost
- fingerprint boost
- new `surfaceflinger_boostpulse`

This gives earlier CPU frequency ramp at animation start without invasive scheduler ABI backports.

### 4) Binder / I/O agility

Keep Binder core unchanged on 3.18 for ABI safety.
Use runtime and scheduler priority strategy instead:
- top-app stune high
- background stune low
- deadline I/O scheduler default
- optional dynamic fsync userspace policy (kernel-level invasive hook intentionally avoided)

---

## Defconfig settings

```config
# Scheduler / prediction
CONFIG_SCHED_TUNE=y
CONFIG_SCHED_WALT=y

# Timer granularity (if symbol exists in your base config)
# CONFIG_HZ_300 is not set
# CONFIG_HZ_1000 is set

# Memory
CONFIG_ZRAM=y
CONFIG_ZRAM_LZ4_COMPRESS=y
CONFIG_ZSWAP=y

# I/O
CONFIG_IOSCHED_DEADLINE=y
# CONFIG_DEFAULT_CFQ is not set
CONFIG_DEFAULT_DEADLINE=y
CONFIG_DEFAULT_IOSCHED="deadline"

# Reduce overhead
# CONFIG_DEBUG_PREEMPT is not set
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_LOCKDEP is not set
# CONFIG_FTRACE is not set
# CONFIG_KPROBES is not set
# CONFIG_PROFILING is not set
# CONFIG_SEC_DEBUG is not set
# CONFIG_KNOX_KAP is not set
# CONFIG_RKP_KDP is not set
# CONFIG_AUDIT is not set
```

## Runtime stune profile (cool + agile)

```sh
# Agile foreground, cool background
echo 90 > /dev/stune/top-app/schedtune.boost
echo 1  > /dev/stune/top-app/schedtune.prefer_idle

echo 15 > /dev/stune/foreground/schedtune.boost
echo 1  > /dev/stune/foreground/schedtune.prefer_idle

echo 0  > /dev/stune/background/schedtune.boost
```
