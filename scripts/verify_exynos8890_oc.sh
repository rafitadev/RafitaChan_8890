#!/system/bin/sh
# shellcheck shell=sh
#
# Verify if Exynos8890 big cluster can actually reach OC top bin (3016 MHz).
# Run as root on-device (Android shell / Termux / adb shell).

set -eu

DURATION_SEC="${1:-20}"
SAMPLE_MS="${2:-100}"
ROUNDS="${3:-3}"
COOLDOWN_SEC="${COOLDOWN_SEC:-2}"
ALLOW_MISSING="${ALLOW_MISSING:-0}"
PREVENTIVE_ON_FAIL="${PREVENTIVE_ON_FAIL:-0}"
CPU_LIST="4 5 6 7"

CPU_POL="/sys/devices/system/cpu/cpu4/cpufreq"
if [ ! -d "${CPU_POL}" ]; then
	# Generic cpufreq fallback for environments exposing policyX only.
	if [ -d /sys/devices/system/cpu/cpufreq/policy0 ]; then
		CPU_POL="/sys/devices/system/cpu/cpufreq/policy0"
		echo "INFO: cpu4 cpufreq path missing, using generic policy path: ${CPU_POL}"
	elif [ "${ALLOW_MISSING}" = "1" ]; then
		echo "WARN: cpufreq sysfs not available in this environment. Skipping runtime test (ALLOW_MISSING=1)."
		exit 0
	else
		echo "ERROR: ${CPU_POL} not found and no /sys/devices/system/cpu/cpufreq/policy0 available."
		echo "Run this on Exynos8890 device with cpufreq enabled, or set ALLOW_MISSING=1 to skip."
		exit 2
	fi
fi

AVAIL="${CPU_POL}/scaling_available_frequencies"
CUR="${CPU_POL}/scaling_cur_freq"
MAX="${CPU_POL}/scaling_max_freq"
GOV="${CPU_POL}/scaling_governor"

if [ ! -r "${AVAIL}" ] || [ ! -r "${CUR}" ] || [ ! -w "${MAX}" ]; then
	echo "ERROR: missing cpufreq permissions/files. Need root and writable scaling_max_freq."
	exit 2
fi

ORIG_GOV="$(cat "${GOV}" 2>/dev/null || true)"
ORIG_MAX="$(cat "${MAX}")"

CPUINFO_MAX="${CPU_POL}/cpuinfo_max_freq"

if [ -r "${CPUINFO_MAX}" ]; then
	cpuinfo_max="$(cat "${CPUINFO_MAX}")"
	echo "cpuinfo_max_freq: ${cpuinfo_max} KHz"
	if [ "${cpuinfo_max}" -lt 3016000 ]; then
		echo "WARN: cpuinfo_max_freq below 3016000 KHz; platform binning/limits may prevent full OC."
	fi
fi

cleanup() {
	for c in ${CPU_LIST}; do
		[ -w "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_max_freq" ] && \
			echo "${ORIG_MAX}" > "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_max_freq" || true
		[ -n "${ORIG_GOV}" ] && [ -w "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_governor" ] && \
			echo "${ORIG_GOV}" > "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_governor" || true
	done
	for p in ${LOAD_PIDS:-}; do
		kill "${p}" 2>/dev/null || true
	done
}
trap cleanup EXIT INT TERM

AVAIL_FREQS="$(tr ' ' '\n' < "${AVAIL}" | sed '/^$/d' | sort -nr)"
TARGET=""
for cand in 3016000; do
	if echo "${AVAIL_FREQS}" | grep -qx "${cand}"; then
		TARGET="${cand}"
		break
	fi
done

if [ -z "${TARGET}" ]; then
	echo "FAIL: 3016000 KHz is not exposed in scaling_available_frequencies."
	echo "Strict mode requires 3016000 as big-core max."
	exit 1
fi

echo "Target frequency: ${TARGET} KHz"
echo "Duration: ${DURATION_SEC}s, sample period: ${SAMPLE_MS}ms, rounds: ${ROUNDS}"

if [ -r "${CPU_POL}/related_cpus" ]; then
	CPU_LIST="$(cat "${CPU_POL}/related_cpus")"
else
	CPU_LIST="4 5 6 7"
fi

for c in ${CPU_LIST}; do
	[ -w "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_governor" ] && \
		echo performance > "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_governor" || true
	[ -w "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_max_freq" ] && \
		echo "${TARGET}" > "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_max_freq" || true
done

LOAD_PIDS=""
for c in ${CPU_LIST}; do
	taskset "0x$((1<<c))" sh -c 'while :; do :; done' >/dev/null 2>&1 &
	LOAD_PIDS="${LOAD_PIDS} $!"
done

overall_peak=0
best_round=0
round=1
samples=$(( (DURATION_SEC * 1000) / SAMPLE_MS ))
tolerance=16000

while [ "${round}" -le "${ROUNDS}" ]; do
	peak=0
	i=0
	while [ "${i}" -lt "${samples}" ]; do
		f="$(cat "${CUR}")"
		[ "${f}" -gt "${peak}" ] && peak="${f}"
		usleep $((SAMPLE_MS * 1000))
		i=$((i + 1))
	done

	echo "Round ${round}: peak ${peak} KHz"
	if [ "${peak}" -gt "${overall_peak}" ]; then
		overall_peak="${peak}"
		best_round="${round}"
	fi

	if [ "${peak}" -ge $((TARGET - tolerance)) ]; then
		echo "PASS: reached target bin in round ${round} (within ${tolerance} KHz tolerance)."
		echo "Observed best peak: ${overall_peak} KHz"
		exit 0
	fi

	round=$((round + 1))
	[ "${round}" -le "${ROUNDS}" ] && sleep "${COOLDOWN_SEC}"
done

echo "FAIL: did not reach requested top bin after ${ROUNDS} rounds."
echo "Observed best peak: ${overall_peak} KHz (best round: ${best_round})"
echo "Hint: check thermal throttling, voltage limits, aging, and silicon bin quality."

if [ "${PREVENTIVE_ON_FAIL}" = "1" ]; then
	fallback="$(echo "${AVAIL_FREQS}" | awk -v t="${TARGET}" '$1 < t { print; exit }')"
	if [ -n "${fallback}" ]; then
		echo "PREVENTIVE: applying fallback max ${fallback} KHz to reduce throttling/reboot risk."
		for c in ${CPU_LIST}; do
			[ -w "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_max_freq" ] && \
				echo "${fallback}" > "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_max_freq" || true
		done
	else
		echo "PREVENTIVE: no lower fallback bin found in scaling_available_frequencies."
	fi
fi

exit 1
