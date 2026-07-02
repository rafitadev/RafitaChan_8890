# Exynos8890 OneUI 6 App Launch Latency Pack

## C patches

### 1) Launch Boost pulse (4-core blast / 5s)

File: `drivers/cpufreq/cpufreq_interactive.c`

- Added `launch_boost_duration` (default `5000000` us)
- Added trigger `launch_boostpulse`
- Trigger routes through existing fingerprint big-core boost path

This gives immediate frequency lock behavior on the big cluster during app cold start window.

### 2) VFS/dentry memory retention

File: `fs/dcache.c`

```diff
-int sysctl_vfs_cache_pressure __read_mostly = 40;
+int sysctl_vfs_cache_pressure __read_mostly = 50;
```

This keeps dentries/inodes alive longer while still allowing reclaim under pressure.

### 3) App-launch read-ahead and reclaim hook

File: `scripts/app_launch_boost.sh`

Implements runtime launch window actions:
- `launch_boostpulse=1`
- `surfaceflinger_boostpulse=1`
- `read_ahead_kb=4096` during launch, restore after 6s
- quick reclaim `compact_memory=1`
- launch writeback ratios (`dirty_background_ratio=5`, `dirty_ratio=20`)

## init.rc integration

```rc
service app_launch_boost /system/bin/sh /vendor/bin/app_launch_boost.sh tiktok
    class late_start
    user root
    group root
    oneshot
```

For production use, call the script from activity/perf daemon hooks with package name.

## Defconfig settings

```config
# Scheduling / boost
CONFIG_SCHED_TUNE=y
CONFIG_SCHED_WALT=y
# CONFIG_SCHED_DEBUG is not set

# Governors
CONFIG_CPU_FREQ_GOV_INTERACTIVE=y
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y

# Memory
CONFIG_ZRAM=y
CONFIG_ZRAM_LZ4_COMPRESS=y
CONFIG_ZSWAP=y

# I/O
CONFIG_IOSCHED_DEADLINE=y
# CONFIG_DEFAULT_CFQ is not set
CONFIG_DEFAULT_DEADLINE=y
CONFIG_DEFAULT_IOSCHED="deadline"

# Overhead removal
# CONFIG_PROFILING is not set
# CONFIG_FTRACE is not set

# F2FS speed-oriented
CONFIG_F2FS_FS=y
# CONFIG_F2FS_CHECK_FS is not set
```
