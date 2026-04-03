#!/usr/bin/env bash
set -euo pipefail

# SukiSU Ultra integration helper for Samsung Exynos8890 (Linux 4.x) trees.
# Usage:
#   bash integrate_sukisu_ultra.sh [path/to/.config]
# Examples:
#   bash integrate_sukisu_ultra.sh
#   bash integrate_sukisu_ultra.sh arch/arm64/configs/exynos8890_defconfig

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PATCH_REPO_MAIN="https://github.com/SukiSU-Ultra/SukiSU_patch"
PATCH_REPO_KP="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch"
OUT_DIFF="sukisu_ultra_integration.diff"

CONFIG_TARGET="${1:-.config}"

WORKDIR="$(mktemp -d -t sukisu-ultra-XXXXXX)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

say() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

apply_one_patch() {
  local patch_file="$1"
  say "Applying patch: ${patch_file}"

  if git am --3way --keep-cr "$patch_file" >/dev/null 2>&1; then
    return 0
  fi

  git am --abort >/dev/null 2>&1 || true

  if git apply --3way --index "$patch_file" >/dev/null 2>&1; then
    git commit -m "SukiSU Ultra: apply $(basename "$patch_file")" >/dev/null 2>&1 || true
    return 0
  fi

  if patch -p1 --forward < "$patch_file" >/dev/null 2>&1; then
    git add -A
    git commit -m "SukiSU Ultra: apply $(basename "$patch_file")" >/dev/null 2>&1 || true
    return 0
  fi

  die "Failed to apply patch: ${patch_file}"
}

apply_patch_series() {
  local repo_dir="$1"
  local label="$2"

  local patch_list="$WORKDIR/${label}_patches.list"
  : > "$patch_list"

  # Prefer explicit series files when present.
  if [[ -f "$repo_dir/series" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" || "$p" =~ ^# ]] && continue
      printf '%s\n' "$repo_dir/$p" >> "$patch_list"
    done < "$repo_dir/series"
  elif [[ -f "$repo_dir/patches/series" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" || "$p" =~ ^# ]] && continue
      printf '%s\n' "$repo_dir/patches/$p" >> "$patch_list"
    done < "$repo_dir/patches/series"
  else
    find "$repo_dir" -type f \( -name '*.patch' -o -name '*.diff' \) | sort -V > "$patch_list"
  fi

  [[ -s "$patch_list" ]] || die "No patches found in ${repo_dir}"

  while IFS= read -r patch_file; do
    [[ -f "$patch_file" ]] || die "Patch listed but missing: $patch_file"
    apply_one_patch "$patch_file"
  done < "$patch_list"
}

enable_cfg_symbol() {
  local cfg_file="$1"
  local sym="$2"

  if grep -qE "^${sym}=y$" "$cfg_file"; then
    return 0
  fi

  if grep -qE "^# ${sym} is not set$" "$cfg_file"; then
    sed -i -E "s|^# ${sym} is not set$|${sym}=y|" "$cfg_file"
  elif grep -qE "^${sym}=" "$cfg_file"; then
    sed -i -E "s|^${sym}=.*$|${sym}=y|" "$cfg_file"
  else
    printf '%s=y\n' "$sym" >> "$cfg_file"
  fi
}

update_kernel_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || {
    warn "Config file not found: $cfg"
    warn "Skipping config updates. Provide config path as first argument to update it."
    return 0
  }

  say "Updating required config options in ${cfg}"
  enable_cfg_symbol "$cfg" CONFIG_KSU
  enable_cfg_symbol "$cfg" CONFIG_KSU_SUSFS
  enable_cfg_symbol "$cfg" CONFIG_KPM
  enable_cfg_symbol "$cfg" CONFIG_KALLSYMS
  enable_cfg_symbol "$cfg" CONFIG_KALLSYMS_ALL

  # Use scripts/config when available for robustness.
  if [[ -x scripts/config ]]; then
    scripts/config --file "$cfg" \
      -e CONFIG_KSU \
      -e CONFIG_KSU_SUSFS \
      -e CONFIG_KPM \
      -e CONFIG_KALLSYMS \
      -e CONFIG_KALLSYMS_ALL || true
  fi

  if [[ "$cfg" == ".config" ]]; then
    if [[ -f Makefile ]]; then
      say "Running olddefconfig to normalize kernel config"
      make olddefconfig >/dev/null
    fi
  fi
}

main() {
  require_cmd git
  require_cmd sed
  require_cmd find
  require_cmd patch

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Run this script inside a git kernel tree"

  local start_commit
  start_commit="$(git rev-parse HEAD)"

  say "Cloning SukiSU patch repositories"
  git clone --depth=1 "$PATCH_REPO_MAIN" "$WORKDIR/SukiSU_patch"
  git clone --depth=1 "$PATCH_REPO_KP" "$WORKDIR/SukiSU_KernelPatch_patch"

  say "Applying SukiSU Ultra patch set (base first, kernel-patch second)"
  apply_patch_series "$WORKDIR/SukiSU_patch" "sukisu_base"
  apply_patch_series "$WORKDIR/SukiSU_KernelPatch_patch" "sukisu_kernelpatch"

  update_kernel_config "$CONFIG_TARGET"

  say "Generating integration diff: ${OUT_DIFF}"
  git diff "$start_commit"..HEAD > "$OUT_DIFF"

  say "Done. Diff file created: ${OUT_DIFF}"
  say "To re-apply elsewhere: git apply ${OUT_DIFF}"
}

main "$@"
