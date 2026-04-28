#!/system/bin/sh
# App launch accelerator profile for heavy OneUI apps.
# Usage: app_launch_boost.sh <pkg-or-process-name>

APP_NAME="$1"
[ -z "$APP_NAME" ] && APP_NAME="unknown"

is_heavy_app=0
case "$APP_NAME" in
  com.ss.android.ugc.trill|com.instagram.android|com.whatsapp)
    is_heavy_app=1
    ;;
esac

write_if_exists() {
  [ -e "$1" ] && echo "$2" > "$1"
}

# Big-core launch blast (5s by kernel parameter)
write_if_exists /sys/module/cpufreq_interactive/parameters/launch_boostpulse 1

# SurfaceFlinger/UI render boost
write_if_exists /sys/module/cpufreq_interactive/parameters/surfaceflinger_boostpulse 1

# Aggressive storage read-ahead during launch window
for q in /sys/block/sd*/queue; do
  if [ "$is_heavy_app" -eq 1 ]; then
    write_if_exists "$q/read_ahead_kb" 4096
  else
    write_if_exists "$q/read_ahead_kb" 2048
  fi
done

# Keep dentries/inodes for fast reopen paths
write_if_exists /proc/sys/vm/vfs_cache_pressure 50

# Quick reclaim nudge
write_if_exists /proc/sys/vm/compact_memory 1

# Keep writeback balanced during launch burst
write_if_exists /proc/sys/vm/dirty_background_ratio 5
write_if_exists /proc/sys/vm/dirty_ratio 20

# Optional: restore read-ahead after short window
(
  sleep 6
  for q in /sys/block/sd*/queue; do
    write_if_exists "$q/read_ahead_kb" 128
  done
) &

exit 0
