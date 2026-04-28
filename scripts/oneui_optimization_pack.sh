#!/system/bin/sh
# OneUI Optimization Pack runtime profile for Exynos8890
# Safe to run from init.d/service scripts; silently skips unavailable knobs.

write_if_exists() {
  [ -e "$1" ] && echo "$2" > "$1"
}

# --- Pageboost ---
write_if_exists /sys/kernel/pageboost/pageboost_active 1
write_if_exists /sys/kernel/pageboost/pageboost_record 1

# --- VM ---
write_if_exists /proc/sys/vm/swappiness 180
write_if_exists /proc/sys/vm/vfs_cache_pressure 40

# --- SchedTune / EAS groups (foreground priority) ---
write_if_exists /dev/stune/top-app/schedtune.boost 90
write_if_exists /dev/stune/top-app/schedtune.prefer_idle 1
write_if_exists /dev/stune/foreground/schedtune.boost 30
write_if_exists /dev/stune/foreground/schedtune.prefer_idle 1
write_if_exists /dev/stune/background/schedtune.boost 0

# --- Fingerprint / Touch boost knobs ---
write_if_exists /sys/module/cpufreq_interactive/parameters/fingerprint_boost_4core_max 1
write_if_exists /sys/module/cpufreq_interactive/parameters/fingerprint_boost_duration 180000
write_if_exists /sys/module/cpufreq_interactive/parameters/input_boost_duration 120000
write_if_exists /sys/module/cpufreq_interactive/parameters/input_boost_freq_big 2002000
write_if_exists /sys/module/cpufreq_interactive/parameters/input_boost_freq_little 1404000

# --- core_ctl: keep big cores online for unlock/UI ---
write_if_exists /sys/devices/system/cpu/core_ctl/min_cpus 4
write_if_exists /sys/devices/system/cpu/core_ctl/max_cpus 4

# --- block / IPC ---
for q in /sys/block/sd*/queue; do
  write_if_exists "$q/iostats" 0
  write_if_exists "$q/nomerges" 2
  write_if_exists "$q/read_ahead_kb" 128
done

# binder: keep strict mode off in production performance profile
write_if_exists /sys/module/binder/parameters/stop_on_user_error 0

exit 0
