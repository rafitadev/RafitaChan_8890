#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KSU_DIR="$ROOT_DIR/drivers/kernelsu"
UPSTREAM_URL="https://github.com/SukiSU-Ultra/SukiSU-Ultra.git"
TMP_DIR="${ROOT_DIR}/.tmp_sukisu_ultra"
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${ROOT_DIR}/drivers/kernelsu_backup_${TS}"

if [ ! -d "$KSU_DIR" ]; then
  echo "KernelSU dir not found: $KSU_DIR" >&2
  exit 1
fi

cp -a "$KSU_DIR" "$BACKUP_DIR"
echo "Backup created: $BACKUP_DIR"

# cleanup stale build artifacts from old drops
find "$KSU_DIR" -type d -name .tmp_versions -prune -exec rm -rf {} + || true
rm -f "$KSU_DIR"/Module.symvers "$KSU_DIR"/modules.order || true

if [ -d "$KSU_DIR/.git" ]; then
  echo "Detected git-managed KernelSU dir"
  git -C "$KSU_DIR" remote set-url origin "$UPSTREAM_URL" || true
  git -C "$KSU_DIR" fetch --tags origin
  LATEST_TAG="$(git -C "$KSU_DIR" tag --sort=-v:refname | head -n1)"
  if [ -z "$LATEST_TAG" ]; then
    LATEST_TAG="origin/main"
  fi
  git -C "$KSU_DIR" checkout "$LATEST_TAG"
else
  rm -rf "$TMP_DIR"
  git clone --depth=1 "$UPSTREAM_URL" "$TMP_DIR"
  rsync -a --delete \
    --exclude '.git' --exclude '.github' \
    "$TMP_DIR/kernel/" "$KSU_DIR/"
  rm -rf "$TMP_DIR"
fi

# 3.18 compatibility sanity checks expected by this tree
rg -n "path_umount|KSU_HAS_PATH_UMOUNT" "$KSU_DIR"/kernel_umount.c >/dev/null
rg -n "vfs_statx|statx" "$KSU_DIR"/kernel_compat.c >/dev/null || true
rg -n "ktime_get_coarse_real_ts64|coarse_real" "$KSU_DIR"/kernel_compat.c >/dev/null || true

# re-apply local compatibility patch if repository keeps one
if [ -f "$ROOT_DIR/patches/sukisu_3.18_compat.patch" ]; then
  git -C "$ROOT_DIR" apply "$ROOT_DIR/patches/sukisu_3.18_compat.patch"
fi

echo "SukiSU-Ultra update completed."
echo "If needed, restore with: rm -rf $KSU_DIR && mv $BACKUP_DIR $KSU_DIR"
