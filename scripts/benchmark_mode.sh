#!/system/bin/sh
# Antutu benchmark burst profile (manual trigger)

write_if_exists() {
  [ -e "$1" ] && echo "$2" > "$1"
}

# Lock big cluster through benchmark_mode pulse (~30s)
write_if_exists /sys/module/cpufreq_interactive/parameters/benchmark_mode 1
# Lock Mali DVFS at max step through governor benchmark mode
write_if_exists /sys/module/gpu_dvfs_governor/parameters/gpu_benchmark_mode 1

# Max read-ahead for synthetic IO tests
for q in /sys/block/sd*/queue; do
  write_if_exists "$q/read_ahead_kb" 2048
done

# Aggressive cache retention
write_if_exists /proc/sys/vm/vfs_cache_pressure 50

# Reduce writeback interference during benchmark burst
write_if_exists /proc/sys/vm/dirty_background_ratio 3
write_if_exists /proc/sys/vm/dirty_ratio 15

exit 0
