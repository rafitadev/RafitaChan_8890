#!/system/bin/sh
# Adaptive Exynos8890 big-cluster OC guard.
# Allows dynamic caps and custom target frequencies.

set -eu

# HIGH_KHZ / LOW_KHZ accept:
# - integer KHz (e.g. 3016000, 2808000, 2600000)
# - "auto"    : highest available frequency
# - "auto-1"  : one step below highest available frequency
HIGH_KHZ="${HIGH_KHZ:-3016000}"
LOW_KHZ="${LOW_KHZ:-3016000}"
TEMP_HIGH_MILLIC="${TEMP_HIGH_MILLIC:-78000}"
TEMP_LOW_MILLIC="${TEMP_LOW_MILLIC:-70000}"
INTERVAL_MS="${INTERVAL_MS:-800}"
ALLOW_MISSING="${ALLOW_MISSING:-0}"
LOCK_MAX_ALWAYS="${LOCK_MAX_ALWAYS:-1}"

pick_policy() {
  if [ -d /sys/devices/system/cpu/cpu4/cpufreq ]; then
    echo "/sys/devices/system/cpu/cpu4/cpufreq"
    return 0
  fi

  for p in /sys/devices/system/cpu/cpufreq/policy4 /sys/devices/system/cpu/cpufreq/policy0; do
    [ -d "$p" ] && { echo "$p"; return 0; }
  done

  return 1
}

read_max_temp() {
  local t z max=0
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$z" ] || continue
    t="$(cat "$z" 2>/dev/null || echo 0)"
    [ "$t" -gt "$max" ] && max="$t"
  done
  echo "$max"
}

apply_cap() {
  local cap="$1"
  local c
  for c in ${CPU_LIST}; do
    [ -w "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_max_freq" ] && \
      echo "$cap" > "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_max_freq" || true
  done
}

resolve_freq() {
  # Args: spec available_freqs(desc, newline)
  local spec="$1"
  local avail="$2"

  if [ -z "$avail" ]; then
    return 1
  fi

  case "$spec" in
    auto)
      echo "$avail" | sed -n '1p'
      return 0
      ;;
    auto-1)
      v="$(echo "$avail" | sed -n '2p')"
      [ -n "$v" ] && { echo "$v"; return 0; }
      echo "$avail" | sed -n '1p'
      return 0
      ;;
    *)
      # Numeric cap request: choose highest available <= requested.
      echo "$avail" | awk -v t="$spec" '$1 <= t { print; exit }'
      return 0
      ;;
  esac
}

if ! CPU_POL="$(pick_policy 2>/dev/null)"; then
  if [ "$ALLOW_MISSING" = "1" ]; then
    echo "WARN: cpufreq policy not found; skipping (ALLOW_MISSING=1)."
    exit 0
  fi
  echo "ERROR: cpufreq policy for big cluster not found."
  exit 2
fi

if [ -r "${CPU_POL}/related_cpus" ]; then
  CPU_LIST="$(cat "${CPU_POL}/related_cpus")"
else
  CPU_LIST="4 5 6 7"
fi

AVAIL=""
if [ -r "${CPU_POL}/scaling_available_frequencies" ]; then
  AVAIL="$(tr ' ' '\n' < "${CPU_POL}/scaling_available_frequencies" | sed '/^$/d' | sort -nr)"
fi

if [ -n "$AVAIL" ]; then
  HIGH_RESOLVED="$(resolve_freq "$HIGH_KHZ" "$AVAIL")"
  LOW_RESOLVED="$(resolve_freq "$LOW_KHZ" "$AVAIL")"
else
  # Fallback defaults if frequency table is missing.
  HIGH_RESOLVED="${HIGH_KHZ#auto}"
  LOW_RESOLVED="${LOW_KHZ#auto-1}"
  [ -z "$HIGH_RESOLVED" ] && HIGH_RESOLVED=3016000
  [ -z "$LOW_RESOLVED" ] && LOW_RESOLVED=2808000
fi

[ -z "$HIGH_RESOLVED" ] && HIGH_RESOLVED=3016000
[ -z "$LOW_RESOLVED" ] && LOW_RESOLVED="$HIGH_RESOLVED"

if [ "$LOW_RESOLVED" -gt "$HIGH_RESOLVED" ]; then
  LOW_RESOLVED="$HIGH_RESOLVED"
fi

if [ "${LOCK_MAX_ALWAYS}" = "1" ]; then
  LOW_RESOLVED="$HIGH_RESOLVED"
fi

mode="high"
last_cap=0

echo "Adaptive OC guard started: HIGH=${HIGH_RESOLVED} LOW=${LOW_RESOLVED} lock_max=${LOCK_MAX_ALWAYS} temp_hi=${TEMP_HIGH_MILLIC} temp_lo=${TEMP_LOW_MILLIC}"

while :; do
  tmax="$(read_max_temp)"

  if [ "${LOCK_MAX_ALWAYS}" != "1" ]; then
    if [ "$mode" = "high" ] && [ "$tmax" -ge "$TEMP_HIGH_MILLIC" ]; then
      mode="low"
    elif [ "$mode" = "low" ] && [ "$tmax" -le "$TEMP_LOW_MILLIC" ]; then
      mode="high"
    fi
  fi

  if [ "$mode" = "high" ]; then
    cap="$HIGH_RESOLVED"
  else
    cap="$LOW_RESOLVED"
  fi

  if [ "$cap" -ne "$last_cap" ]; then
    apply_cap "$cap"
    echo "Adaptive OC: temp=${tmax} -> cap=${cap} (${mode})"
    last_cap="$cap"
  fi

  usleep $((INTERVAL_MS * 1000))
done
