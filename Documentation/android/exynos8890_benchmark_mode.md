# Exynos8890 Benchmark Mode (Antutu-Oriented)

## C patches (CPU/GPU path first)

### 1) CPU benchmark_mode toggle in interactive governor

File: `drivers/cpufreq/cpufreq_interactive.c`

Implemented:
- `benchmark_mode_duration` (default: 30s)
- `benchmark_mode` trigger (`module_param_cb`)
- On trigger:
  - lock big cluster policy to `policy->max`
  - set long boost pulse (`benchmark_mode_duration`)
  - wake speedchange task immediately

Runtime trigger:
```sh
echo 1 > /sys/module/cpufreq_interactive/parameters/benchmark_mode
```

### 2) GPU turbo policy (runtime)

Use existing Exynos Mali sysfs lock interface with script trigger during benchmark run:
- lock max GPU clock (up to configured limit)
- keep high bus devfreq floor

(Driver-level hard lock is intentionally runtime-driven to avoid thermal runaway in daily use.)

### 3) IRQ/background offload during benchmark

Use staged script profile to reduce background I/O pressure and kernel writeback interruptions while keeping system stable.

## Scripts / tunables

### `scripts/benchmark_mode.sh`

Applies benchmark burst profile:
- triggers governor benchmark mode
- sets `read_ahead_kb=2048`
- sets `vfs_cache_pressure=50`
- uses lower dirty ratios for benchmark window

## Defconfig strip-down list

```config
# Sched / latency
CONFIG_SCHED_TUNE=y
CONFIG_SCHED_WALT=y
CONFIG_CPU_FREQ_GOV_INTERACTIVE=y
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y

# Timer
# CONFIG_HZ_300 is not set
# CONFIG_HZ_1000 is set

# Memory / IO
CONFIG_ZRAM=y
CONFIG_ZRAM_LZ4_COMPRESS=y
CONFIG_ZSWAP=y
CONFIG_IOSCHED_DEADLINE=y
# CONFIG_DEFAULT_CFQ is not set
CONFIG_DEFAULT_DEADLINE=y
CONFIG_DEFAULT_IOSCHED="deadline"

# Security/debug overhead removal
# CONFIG_SCHED_DEBUG is not set
# CONFIG_PROFILING is not set
# CONFIG_FTRACE is not set
# CONFIG_KPROBES is not set
# CONFIG_DEBUG_INFO is not set
# CONFIG_KALLSYMS is not set
# CONFIG_KNOX_KAP is not set
# CONFIG_RKP_KDP is not set
# CONFIG_TIMA is not set
```

## Notes

- `CONFIG_MGLRU` and scheduler uclamp are not native in this vendor 3.18 baseline; full support requires deep subsystem backports.
- Use benchmark mode only for short benchmark runs due to thermal and battery stress.
