#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

required_patterns=(
  "drivers/clk/samsung/clk-exynos8890.c:3016000000"
  "drivers/soc/samsung/pwrcal/S5E8890/S5E8890-cmu.c:3016000000"
  "drivers/soc/samsung/pwrcal/S5E8890/S5E8890-pll.c:3016000000"
  "drivers/cpufreq/exynos-mp-cpufreq.c:3016000"
  "drivers/cpufreq/exynos-mp-cpufreq-cal.c:3016000"
  "arch/arm64/boot/exynos8890_Oneui.dtsi:cl1_dvfs_table = < 0 3016000 1325000"
  "arch/arm64/boot/exynos8890_Treble.dtsi:cl1_dvfs_table = < 0 3016000 1325000"
  "scripts/runtime_tune_universal.sh:TARGET_BIG_MAX_KHZ"
  "scripts/runtime_tune_universal.sh:3016000"
)

for item in "${required_patterns[@]}"; do
  file="${item%%:*}"
  pattern="${item#*:}"
  if ! rg -q --fixed-strings "${pattern}" "${file}"; then
    echo "FAIL: missing pattern '${pattern}' in ${file}"
    exit 1
  fi
done

# Block only exact OC-frequency leftovers; ignore unrelated hex constants.
forbid_patterns=(
  "(^|[^0-9])3020000([^0-9]|$)"
  "(^|[^0-9])3020000000([^0-9]|$)"
  "3\\.02GHz"
  "3\\.020GHz"
)

check_scope=(
  "drivers/clk/samsung/clk-exynos8890.c"
  "drivers/soc/samsung/pwrcal/S5E8890/S5E8890-cmu.c"
  "drivers/soc/samsung/pwrcal/S5E8890/S5E8890-pll.c"
  "drivers/cpufreq/exynos-mp-cpufreq.c"
  "drivers/cpufreq/exynos-mp-cpufreq-cal.c"
  "arch/arm64/boot/exynos8890_Oneui.dtsi"
  "arch/arm64/boot/exynos8890_Treble.dtsi"
  "arch/arm64/boot/dts/exynos8890-herolte_common.dtsi"
  "arch/arm64/boot/dts/exynos8890-gracelte_common.dtsi"
  "scripts/runtime_tune_universal.sh"
  "docs/UNIVERSAL_S7E_KERNEL.md"
)

for pattern in "${forbid_patterns[@]}"; do
  if rg -n -P "${pattern}" "${check_scope[@]}" >/dev/null; then
    echo "FAIL: forbidden pattern '${pattern}' still present in scoped files"
    rg -n -P "${pattern}" "${check_scope[@]}"
    exit 1
  fi
done

echo "OK: Exynos8890 3016MHz consistency checks passed."
