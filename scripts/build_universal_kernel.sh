#!/usr/bin/env bash
set -euo pipefail

# Universal build helper for Exynos8890 (S7/S7 Edge variants)
# Usage:
#   ./scripts/build_universal_kernel.sh [profile|defconfig]
# Example:
#   ./scripts/build_universal_kernel.sh treble
#   ./scripts/build_universal_kernel.sh oneui
#   ./scripts/build_universal_kernel.sh exynos8890_defconfig

PROFILE="${1:-${DEFCONFIG:-exynos8890_defconfig}}"
ARCH=arm64
SUBARCH=arm64
JOBS="${JOBS:-$(nproc)}"
OUT_DIR="${OUT_DIR:-out}"

# Optional: set TOOLCHAIN_BIN to a bin directory containing
# aarch64-linux-*-gcc binaries.
TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-}"

case "$PROFILE" in
  oneui) DEFCONFIG="oneui_defconfig" ;;
  treble) DEFCONFIG="treble_defconfig" ;;
  exynos8890|stock) DEFCONFIG="exynos8890_defconfig" ;;
  *_defconfig) DEFCONFIG="$PROFILE" ;;
  *) DEFCONFIG="${DEFCONFIG:-exynos8890_defconfig}" ;;
esac

select_toolchain_prefix() {
  local requested="${CROSS_COMPILE:-}"
  local candidates=()

  if [ -n "$requested" ]; then
    candidates+=("$requested")
  fi

  candidates+=(
    "aarch64-linux-android-"
    "aarch64-linux-gnu-"
    "aarch64-none-elf-"
  )

  local prefix
  for prefix in "${candidates[@]}"; do
    if command -v "${prefix}gcc" >/dev/null 2>&1; then
      echo "$prefix"
      return 0
    fi
  done

  return 1
}

if [ -n "$TOOLCHAIN_BIN" ]; then
  export PATH="$TOOLCHAIN_BIN:$PATH"
fi

if ! TOOLCHAIN_PREFIX="$(select_toolchain_prefix)"; then
  echo "ERROR: no AArch64 cross-compiler found in PATH."
  echo ""
  echo "Expected one of:"
  echo "  - aarch64-linux-android-gcc"
  echo "  - aarch64-linux-gnu-gcc"
  echo "  - aarch64-none-elf-gcc"
  echo ""
  echo "Fix options:"
  echo "  1) Export CROSS_COMPILE with your installed prefix."
  echo "     ex.: CROSS_COMPILE=/opt/toolchains/gcc/bin/aarch64-linux-gnu-"
  echo "  2) Export TOOLCHAIN_BIN for the toolchain bin directory."
  echo "     ex.: TOOLCHAIN_BIN=/opt/toolchains/gcc/bin"
  echo ""
  echo "This script does not auto-download toolchains to avoid flaky 403/proxy failures."
  exit 2
fi

export ARCH SUBARCH
export CROSS_COMPILE="$TOOLCHAIN_PREFIX"
export ANDROID_MAJOR_VERSION="${ANDROID_MAJOR_VERSION:-q}"
export DEFCONFIG

mkdir -p "$OUT_DIR"

echo "[+] Building with defconfig: $DEFCONFIG"
echo "[+] Using toolchain prefix: $CROSS_COMPILE"
make O="$OUT_DIR" "$DEFCONFIG"
make -j"$JOBS" O="$OUT_DIR"

echo "[+] Build complete"
echo "    Image.gz-dtb: $OUT_DIR/arch/arm64/boot/Image.gz-dtb"
echo "    DTB(s):        $OUT_DIR/arch/arm64/boot/dts/"
