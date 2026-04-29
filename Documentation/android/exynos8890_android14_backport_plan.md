# Exynos8890 Android 14 (One UI 6) Kernel Backport Plan

## Patches (C code)

### 1) Biometric prewarm hook (50ms pre-auth boost)

Applied in `drivers/cpufreq/cpufreq_interactive.c`:

- Added `biometric_prewarm_duration` (default `50000` us)
- Added trigger node `biometric_preboostpulse`
- Trigger reuses fingerprint boost path with a short prewarm pulse

Userspace integration (biometric HAL/daemon):
```sh
# trigger ~50ms before auth completion
echo 1 > /sys/module/cpufreq_interactive/parameters/biometric_preboostpulse
```

### 2) MGLRU backport status for 3.18

Full MGLRU requires deep MM changes across:
- `mm/vmscan.c`
- rmap / anon/file aging paths
- memcg + reclaim policy integration

For this tree, recommended staged path is:
1. keep current pageboost + kswapd throttle path;
2. add MGLRU infrastructure branch-by-branch (no partial cherry-pick into production);
3. validate with long memory pressure soak before rollout.

### 3) Uclamp/PELT status

Native uclamp is not available in this vendor 3.18 baseline.
Use existing equivalent controls:
- `schedtune.boost` groups
- input/fingerprint/surfaceflinger/biometric pulse hooks

This provides Android 14 UI responsiveness without destabilizing scheduler ABI.

### 4) Network and I/O

- BBR is not present in this kernel baseline by default; enabling it needs a dedicated TCP stack backport.
- Keep deadline scheduler + Wi-Fi highperf mode + runtime stune profile for low-latency behavior on One UI 6.

### 5) Vulkan/UI smoothness

Use combined hooks already present:
- input boost,
- fingerprint 4-core boost,
- surfaceflinger boostpulse,
- biometric preboostpulse.

This aligns CPU ramp-up with UI transitions and unlock animations.

---

## Defconfig settings (Android 14-oriented)

```config
# Scheduler / latency
CONFIG_SCHED_TUNE=y
CONFIG_SCHED_WALT=y
CONFIG_PREEMPT=y
# CONFIG_PREEMPT_VOLUNTARY is not set

# Timer granularity (if symbol exists)
# CONFIG_HZ_300 is not set
# CONFIG_HZ_1000 is set

# Memory
CONFIG_ZRAM=y
CONFIG_ZRAM_LZ4_COMPRESS=y
CONFIG_ZSWAP=y

# I/O default
CONFIG_IOSCHED_DEADLINE=y
# CONFIG_DEFAULT_CFQ is not set
CONFIG_DEFAULT_DEADLINE=y
CONFIG_DEFAULT_IOSCHED="deadline"

# Disable overhead / incompatible debug
# CONFIG_SCHED_DEBUG is not set
# CONFIG_PANIC_ON_REBOOT_TIMEOUT is not set
# CONFIG_SEC_DEBUG is not set
# CONFIG_SEC_DEBUG_LAST_KMSG is not set
# CONFIG_KNOX_KAP is not set
# CONFIG_RKP_KDP is not set
# CONFIG_TIMA is not set
# CONFIG_AUDIT is not set
```

## Runtime One UI 6 profile

```sh
# top-app aggressive, background cool
echo 90 > /dev/stune/top-app/schedtune.boost
echo 1 > /dev/stune/top-app/schedtune.prefer_idle

echo 15 > /dev/stune/foreground/schedtune.boost
echo 1 > /dev/stune/foreground/schedtune.prefer_idle

echo 0 > /dev/stune/background/schedtune.boost
```
