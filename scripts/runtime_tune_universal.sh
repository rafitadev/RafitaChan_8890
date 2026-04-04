#!/system/bin/sh
# Runtime performance profile for Exynos8890 Treble/OneUI/AOSP.
# Execute as root after boot. Values are conservative-aggressive.

set -eu

set_if_exists() {
  [ -e "$1" ] && echo "$2" > "$1"
}

# VM tuning
set_if_exists /proc/sys/vm/swappiness 20
set_if_exists /proc/sys/vm/dirty_ratio 12
set_if_exists /proc/sys/vm/dirty_background_ratio 4
set_if_exists /proc/sys/vm/vfs_cache_pressure 60
set_if_exists /proc/sys/vm/dirty_expire_centisecs 200
set_if_exists /proc/sys/vm/dirty_writeback_centisecs 100

# Block queue tuning
for q in /sys/block/*/queue; do
  [ -d "$q" ] || continue
  set_if_exists "$q/read_ahead_kb" 256
  if [ -e "$q/scheduler" ]; then
    if grep -q "noop" "$q/scheduler"; then
      echo noop > "$q/scheduler"
    elif grep -q "deadline" "$q/scheduler"; then
      echo deadline > "$q/scheduler"
    fi
  fi
  set_if_exists "$q/iostats" 0
  set_if_exists "$q/add_random" 0
done

# CPU governor tuning (interactive)
for gov in /sys/devices/system/cpu/cpufreq/interactive /sys/devices/system/cpu/cpu*/cpufreq/interactive; do
  [ -d "$gov" ] || continue
  set_if_exists "$gov/go_hispeed_load" 88
  set_if_exists "$gov/min_sample_time" 40000
  set_if_exists "$gov/timer_rate" 15000
  set_if_exists "$gov/target_loads" "80 1300000:85 1900000:90"
done

# Optional CPU ceilings (safe upper bounds for OC builds)
set_if_exists /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2106000
set_if_exists /sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq 3016000

exit 0
