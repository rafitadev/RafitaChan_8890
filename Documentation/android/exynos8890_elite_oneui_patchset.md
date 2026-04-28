# Exynos8890 Elite OneUI Patchset

## Patches (C code)

### 1) Wi-Fi High Performance Mode (bcmdhd)

File: `drivers/net/wireless/bcmdhd_100_15/dhd_linux.c`

```diff
+uint dhd_wifi_highperf_mode = 1;
+module_param(dhd_wifi_highperf_mode, uint, 0644);
@@
- power_mode = PM_FAST;
+ power_mode = PM_FAST;
+ if (dhd_wifi_highperf_mode)
+     power_mode = PM_OFF;
  dhd_wl_ioctl_cmd(dhd, WLC_SET_PM, (char *)&power_mode,
                   sizeof(power_mode), TRUE, 0);
```

Effect:
- Keeps firmware power-save disabled on resume path (`PM_OFF`) for lower latency and fewer packet drops under gaming/streaming.

Runtime toggle:
```sh
echo 1 > /sys/module/bcmdhd/parameters/dhd_wifi_highperf_mode
```

### 2) GPU/Display boost sync path

Already present in tree and should be kept:
- input/fingerprint boost hook in `cpufreq_interactive`
- DECON scheduling priority path for smoother frame dispatch

Operational recommendation:
- keep fingerprint 4-core max boost active
- keep top-app `schedtune.boost` high (90 in runtime profile)

### 3) Charging / NFE safety policy

For NFE batteries, this tree should use DTS charge current/float adjustments instead of unsafe hard-coded charger bypass logic.
Recommended approach:
- tune charging ceilings in DTS battery nodes already used by device variants.
- avoid introducing direct battery bypass without PMIC-specific validation.

### 4) Audio high-gain mode

This tree exposes `moro_sound` controls. Current safe headroom increase:
- `SPEAKER_MAX` raised to `66` in `sound/soc/codecs/moro_sound.h`.

Use runtime control through moro_sound sysfs to avoid hard-clipping.

## Defconfig settings

### I/O Scheduler (UFS-focused)

```config
CONFIG_IOSCHED_NOOP=y
CONFIG_IOSCHED_DEADLINE=y
CONFIG_IOSCHED_CFQ=y
# CONFIG_DEFAULT_CFQ is not set
CONFIG_DEFAULT_DEADLINE=y
# CONFIG_DEFAULT_NOOP is not set
CONFIG_DEFAULT_IOSCHED="deadline"
```

### ZRAM / ZSWAP

```config
CONFIG_ZSMALLOC=y
CONFIG_ZRAM=y
CONFIG_ZRAM_LZ4_COMPRESS=y
CONFIG_ZSWAP=y
# CONFIG_ZSWAP_ENABLE_WRITEBACK is not set
# CONFIG_ZSWAP_COMPACTION is not set
```

### Clean & Fast block

```config
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_SLUB_DEBUG is not set
# CONFIG_DEBUG_PREEMPT is not set
# CONFIG_STACKTRACE is not set
# CONFIG_LOCKDEP is not set
# CONFIG_SCHED_DEBUG is not set
# CONFIG_FTRACE is not set
# CONFIG_KPROBES is not set
# CONFIG_PROFILING is not set

# Samsung overhead
# CONFIG_SEC_DEBUG is not set
# CONFIG_SEC_DEBUG_LAST_KMSG is not set
# CONFIG_KNOX_KAP is not set
# CONFIG_RKP_KDP is not set
# CONFIG_TIMA is not set

CONFIG_HZ_300=y
CONFIG_TREE_RCU=y
# CONFIG_RCU_FAST_NO_HZ is not set
```

> Note: `CONFIG_RCU_FAST_NO_HZ` is not available in all 3.18 vendor trees; keep disabled unless symbol exists.

## Cronos integration

```sh
export KCFLAGS="-O3 -mcpu=exynos-m1 -mtune=exynos-m1 -fgraphite-identity -floop-block"
# optional aggressive:
# export KCFLAGS="$KCFLAGS -Ofast -funsafe-math-optimizations"
bash cronos.sh
```

Apply runtime profile after boot:
```sh
sh scripts/oneui_optimization_pack.sh
```
