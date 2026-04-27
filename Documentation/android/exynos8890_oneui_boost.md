# Exynos 8890 (Galaxy S7 Edge) OneUI Performance Profile (Kernel 3.18)

## Applied baseline

This tree now includes:

- higher global swappiness tuned for zRAM-backed swap;
- lower VFS cache pressure to preserve hot app metadata/dentries;
- a less aggressive early-kill LMK profile with 6 tiers;
- input-driven interactive governor boost pulses for both clusters;
- HMP migration defaults tuned for faster up-migration and steadier down-migration;
- Mali T880 interactive DVFS defaults optimized for frame-time stability.
- vmscan mem_boost + kswapd throttle sysfs hook for pageboost-style reclaim pacing.
- fingerprint-triggered CPU boostpulse entry point through cpufreq_interactive module params.

## Backport map (community patch parity)

For the extended low-level driver roadmap (ASV/UFS/DECON/G2D/ASoC/Wi-Fi/Sensorhub/IPA),
see `Documentation/android/exynos8890_massive_backport_plan.md`.

For the full Exynos 9810/N770F pageboost and M625F kswapd-throttle behavior, use:

- `mm/vmscan.c`: port reclaim mode state machine first (mem_boost/pageboost gate),
  then wire kswapd pacing (`mem_boost_kswapd_throttle_ms`) and watermark bias.
- `include/trace/events/vmscan.h`: keep tracepoints compatible with 3.18 symbols.
- `mm/Kconfig` + `kernel/sysctl.c`: add only control knobs used by reclaim; **do not**
  port vmalloc-era internals (3.18 instability risk).

For sdcardfs/overlayfs modernization:

- `fs/sdcardfs/*`: sync permission/pathwalk fixes from 4.4 branch first.
- `fs/overlayfs/*`: cherry-pick copy-up and readdir race fixes only; avoid
  inode/dcache API migrations requiring post-4.9 helpers.

## OneUI 4.1 implementation notes (this tree)

### 1) Sched/Input boost
- `drivers/cpufreq/cpufreq_interactive.c` now triggers `set_hmp_boostpulse()`
  from both touch input path and fingerprint boost path, so task migration to
  big cores reacts together with freq ramp.
- `drivers/video/fbdev/exynos/decon_8890/{decon_core.c,decon_dsi.c}` run
  DECON worker/vsync threads in `SCHED_FIFO` priorities.

### 2) GPU policy
- `drivers/gpu/arm/t8xx/r12p0_n/backend/gpu/mali_kbase_pm_policy.c` puts
  `always_on` policy first (default) for stutter-sensitive UI rendering.
- `drivers/gpu/arm/t8xx/r12p0_n/platform/exynos/gpu_dvfs_governor.c` adds a
  `gpu_default_ticks` downscale gate (Bifrost-like default_ticks behavior).

### 3) Battery/Store mode
- `arch/arm64/boot/dts/exynos8890-{herolte,hero2lte,gracelte_common}_battery*.dtsi`
  include:
  `factory_store_mode_max/min` and store-mode current limits.
- `CONFIG_STORE_MODE=y` in defconfig exposes runtime control via battery sysfs.

### 4) Memory/IO and APEX loop
- `mm/vmscan.c`: mem_boost kswapd pacing with
  `/sys/kernel/vmscan/mem_boost_kswapd_throttle_ms`.
- Defconfig loopback is raised for modern userspace images:
  `loop.max_part=63`, `CONFIG_BLK_DEV_LOOP_MIN_COUNT=64`.

## Overclock integration points (CPU/GPU)

Use these files when adding new OPP bins for Exynos 8890:

- `drivers/cpufreq/exynos-mp-cpufreq.c` and `drivers/cpufreq/exynos-mp-cpufreq-cal.c`
  for policy/frequency table hooks.
- `drivers/soc/samsung/pwrcal/S5E8890/S5E8890-dfs.c`
  for DFS tables and clock transition data.
- `drivers/soc/samsung/pwrcal/S5E8890/S5E8890-asv.c`
  for ASV voltage mapping and per-bin voltage offsets.
- `drivers/soc/samsung/pwrcal/S5E8890/S5E8890-pll.c`
  for PLL rate support and clock parent constraints.
- `drivers/gpu/arm/t8xx/r12p0_n/platform/exynos/gpu_exynos8890.c`
  for Mali DVFS table clocks/voltages.

## Safe OC table template (example)

```c
/*
 * Frequency in kHz, voltage in uV.
 * Keep step deltas small and validate with thermal throttling enabled.
 */
struct exynos_oc_opp {
	unsigned int freq_khz;
	unsigned int volt_uv;
};

static struct exynos_oc_opp mongoose_cluster_oc[] = {
	{2314000, 1037500},
	{2392000, 1075000}, /* validate leakage/temperature per ASV group */
};

static struct exynos_oc_opp mali_t880_oc[] = {
	{806000, 850000},
	{900000, 900000},   /* sample OC point; validate long stress + skin temp */
};
```

## Practical voltage limits (engineering guidance)

- M1 (big) daily-use ceiling: around `1,100,000 uV` for sustainable thermals.
- A53 (little) daily-use ceiling: around `1,000,000 uV`.
- Mali T880 daily-use ceiling: around `950,000 uV`.

Any value above these should be treated as short-burst benchmarking only and
must be paired with strict thermal trip points and rollback fallback OPPs.
