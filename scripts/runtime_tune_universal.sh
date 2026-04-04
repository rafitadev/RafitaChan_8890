#!/system/bin/sh
# Runtime performance profile for Exynos8890 Treble/OneUI/AOSP.
# Execute as root after boot. Values are conservative-aggressive with OC safeguards.

set -eu

TARGET_BIG_MAX_KHZ="${TARGET_BIG_MAX_KHZ:-3016000}"
TARGET_LITTLE_MAX_KHZ="${TARGET_LITTLE_MAX_KHZ:-2106000}"

set_if_exists() {
  [ -e "$1" ] && echo "$2" > "$1"
}

pick_cpufreq_policy() {
  # Prefer big cluster policy if exposed by per-cpu path.
  if [ -d /sys/devices/system/cpu/cpu4/cpufreq ]; then
    echo "/sys/devices/system/cpu/cpu4/cpufreq"
    return 0
  fi

  # Fallback policy paths (some kernels expose only policyX).
  for p in /sys/devices/system/cpu/cpufreq/policy4 /sys/devices/system/cpu/cpufreq/policy0; do
    [ -d "$p" ] && { echo "$p"; return 0; }
  done

  return 1
}

select_safe_max_freq() {
  # Args: policy_path target_khz
  local policy="$1"
  local target="$2"
  local avail="${policy}/scaling_available_frequencies"
  local cpuinfo_max="${policy}/cpuinfo_max_freq"
  local cap="${target}"

  if [ -r "${cpuinfo_max}" ]; then
    local ci
    ci="$(cat "${cpuinfo_max}")"
    [ "${ci}" -lt "${cap}" ] && cap="${ci}"
  fi

  if [ -r "${avail}" ]; then
    tr ' ' '\n' < "${avail}" | sed '/^$/d' | sort -nr | while read -r f; do
      [ "${f}" -le "${cap}" ] && { echo "${f}"; break; }
    done
  else
    echo "${cap}"
  fi
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

# Little cluster ceiling (safe fixed cap)
set_if_exists /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq "${TARGET_LITTLE_MAX_KHZ}"

# Big cluster ceiling (preventive: never request unsupported bin)
if BIG_POLICY="$(pick_cpufreq_policy 2>/dev/null)"; then
  SAFE_BIG_MAX="$(select_safe_max_freq "${BIG_POLICY}" "${TARGET_BIG_MAX_KHZ}")"

  if [ -n "${SAFE_BIG_MAX}" ]; then
    if [ "${SAFE_BIG_MAX}" -lt "${TARGET_BIG_MAX_KHZ}" ]; then
      echo "INFO: applying preventive big max ${SAFE_BIG_MAX} KHz (target ${TARGET_BIG_MAX_KHZ} KHz unsupported in current conditions)."
    else
      echo "INFO: applying big max ${SAFE_BIG_MAX} KHz."
    fi

    if [ -r "${BIG_POLICY}/related_cpus" ]; then
      CPU_LIST="$(cat "${BIG_POLICY}/related_cpus")"
    else
      CPU_LIST="4 5 6 7"
    fi

    for c in ${CPU_LIST}; do
      set_if_exists "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_max_freq" "${SAFE_BIG_MAX}"
    done
  fi
else
  # Legacy fallback path
  set_if_exists /sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq "${TARGET_BIG_MAX_KHZ}"
fi

exit 0
