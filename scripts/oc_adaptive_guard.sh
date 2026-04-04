#!/system/bin/sh
# Adaptive Exynos8890 big-cluster OC guard.
# Goal: allow burst to 3016MHz, but fall back near 2808MHz when hot.
# This mimics the "2.8 -> 3.0 -> 2.8" behavior users expect under real load.

set -eu

HIGH_KHZ="${HIGH_KHZ:-3016000}"
LOW_KHZ="${LOW_KHZ:-2808000}"
TEMP_HIGH_MILLIC="${TEMP_HIGH_MILLIC:-78000}"
TEMP_LOW_MILLIC="${TEMP_LOW_MILLIC:-70000}"
INTERVAL_MS="${INTERVAL_MS:-800}"
ALLOW_MISSING="${ALLOW_MISSING:-0}"

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

# Clamp HIGH/LOW to available frequencies if possible.
if [ -r "${CPU_POL}/scaling_available_frequencies" ]; then
  AVAIL="$(tr ' ' '\n' < "${CPU_POL}/scaling_available_frequencies" | sed '/^$/d' | sort -nr)"
  hi_candidate="$(echo "${AVAIL}" | awk -v t="${HIGH_KHZ}" '$1 <= t { print; exit }')"
  lo_candidate="$(echo "${AVAIL}" | awk -v t="${LOW_KHZ}" '$1 <= t { print; exit }')"
  [ -n "${hi_candidate}" ] && HIGH_KHZ="${hi_candidate}"
  [ -n "${lo_candidate}" ] && LOW_KHZ="${lo_candidate}"
fi

if [ "$LOW_KHZ" -gt "$HIGH_KHZ" ]; then
  LOW_KHZ="$HIGH_KHZ"
fi

mode="high"
last_cap=0

echo "Adaptive OC guard started: HIGH=${HIGH_KHZ} LOW=${LOW_KHZ} temp_hi=${TEMP_HIGH_MILLIC} temp_lo=${TEMP_LOW_MILLIC}"

while :; do
  tmax="$(read_max_temp)"

  if [ "$mode" = "high" ] && [ "$tmax" -ge "$TEMP_HIGH_MILLIC" ]; then
    mode="low"
  elif [ "$mode" = "low" ] && [ "$tmax" -le "$TEMP_LOW_MILLIC" ]; then
    mode="high"
  fi

  if [ "$mode" = "high" ]; then
    cap="$HIGH_KHZ"
  else
    cap="$LOW_KHZ"
  fi

  if [ "$cap" -ne "$last_cap" ]; then
    apply_cap "$cap"
    echo "Adaptive OC: temp=${tmax} -> cap=${cap} (${mode})"
    last_cap="$cap"
  fi

  usleep $((INTERVAL_MS * 1000))
done
