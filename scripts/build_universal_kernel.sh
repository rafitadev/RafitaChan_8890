#!/usr/bin/env bash
set -euo pipefail

# Universal build helper for Exynos8890 (S7/S7 Edge variants)
# Usage:
#   ./scripts/build_universal_kernel.sh [profile|defconfig]
# Example:
#   ./scripts/build_universal_kernel.sh treble
#   ./scripts/build_universal_kernel.sh oneui
#   ./scripts/build_universal_kernel.sh exynos8890_defconfig

PROFILE="${1:-exynos8890_defconfig}"
ARCH=arm64
SUBARCH=arm64
JOBS="${JOBS:-$(nproc)}"
OUT_DIR="${OUT_DIR:-out}"
TOOLCHAIN_PREFIX="${CROSS_COMPILE:-aarch64-linux-android-}"

case "$PROFILE" in
  oneui) DEFCONFIG="oneui_defconfig" ;;
  treble) DEFCONFIG="treble_defconfig" ;;
  exynos8890|stock) DEFCONFIG="exynos8890_defconfig" ;;
  *_defconfig) DEFCONFIG="$PROFILE" ;;
  *) DEFCONFIG="exynos8890_defconfig" ;;
esac

export ARCH SUBARCH
export CROSS_COMPILE="$TOOLCHAIN_PREFIX"
export ANDROID_MAJOR_VERSION="${ANDROID_MAJOR_VERSION:-q}"

mkdir -p "$OUT_DIR"

echo "[+] Building with defconfig: $DEFCONFIG"
make O="$OUT_DIR" "$DEFCONFIG"
make -j"$JOBS" O="$OUT_DIR"

echo "[+] Build complete"
echo "    Image.gz-dtb: $OUT_DIR/arch/arm64/boot/Image.gz-dtb"
echo "    DTB(s):        $OUT_DIR/arch/arm64/boot/dts/"
