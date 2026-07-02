#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT_DIR/arch/arm64/configs/cronos_defconfig"
BASE="$ROOT_DIR/arch/arm64/configs/exynos8890_defconfig"

ensure_cfg() {
  local file="$1" key="$2" val="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  elif grep -qE "^# ${key} is not set$" "$file"; then
    sed -i "s|^# ${key} is not set$|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

ensure_unset() {
  local file="$1" key="$2"
  sed -i "/^${key}=.*/d" "$file"
  if ! grep -qE "^# ${key} is not set$" "$file"; then
    echo "# ${key} is not set" >> "$file"
  fi
}

# Performance stack for Cronos merged config
ensure_cfg "$CFG" CONFIG_F2FS_FS y
ensure_cfg "$CFG" CONFIG_F2FS_FS_SECURITY y
ensure_cfg "$BASE" CONFIG_SAMSUNG_PAGEBOOST y
ensure_cfg "$BASE" CONFIG_PAGEBOOST_IO_BOOST y
ensure_cfg "$BASE" CONFIG_MALI_R30P0 y
ensure_cfg "$BASE" CONFIG_CPU_THERMAL_IPA y
ensure_cfg "$BASE" CONFIG_CPU_THERMAL_IPA_CONTROL y
ensure_cfg "$BASE" CONFIG_HOTPLUG_CPU y
ensure_cfg "$BASE" CONFIG_KSU y
ensure_unset "$BASE" CONFIG_KSU_DEBUG

# Low overhead defaults
ensure_unset "$BASE" CONFIG_SEC_DEBUG
ensure_unset "$BASE" CONFIG_PROFILING
ensure_unset "$BASE" CONFIG_FTRACE

echo "Cronos prebuild tuning applied."
