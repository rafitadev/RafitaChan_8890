#!/usr/bin/env bash
set -euo pipefail

# SukiSU Ultra 3.x safe integrator (Exynos8890-oriented)
# - deterministic patch order: SukiSU_patch -> SukiSU_KernelPatch_patch
# - header validation + hard stop on conflicts
# - minimal config enablement; SUSFS optional (default OFF for stability)
# - minimal BPF enablement only when symbol exists
# - generates sukisu_ultra_integration_3x.diff from pre-integration HEAD
# - no boot automation scripts
#
# Usage:
#   bash integrate_sukisu_ultra.sh [config_path]
#
# Environment:
#   ENABLE_SUSFS=1   # optional/risky, default 0
#   SKIP_BUILD=1     # skip compile check, default 1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PATCH_REPO_BASE="https://github.com/SukiSU-Ultra/SukiSU_patch"
PATCH_REPO_KP="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch"
OUT_DIFF="sukisu_ultra_integration_3x.diff"
CONFIG_FILE="${1:-.config}"
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
SKIP_BUILD="${SKIP_BUILD:-1}"

WORKDIR="$(mktemp -d -t sukisu-3x-XXXXXX)"
START_COMMIT=""

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
fail() { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

require_clean_tree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty. Commit/stash changes before running."
  fi
}

validate_patch_header() {
  local patch_file="$1"
  grep -qE '^(From [0-9a-f]{7,40}|diff --git )' "$patch_file" || fail "Invalid patch header: $patch_file"
}

build_patch_list() {
  local src_dir="$1"
  local out_list="$2"
  : > "$out_list"

  if [[ -f "$src_dir/series" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      printf '%s\n' "$src_dir/$line" >> "$out_list"
    done < "$src_dir/series"
  elif [[ -f "$src_dir/patches/series" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      printf '%s\n' "$src_dir/patches/$line" >> "$out_list"
    done < "$src_dir/patches/series"
  else
    find "$src_dir" -type f \( -name '*.patch' -o -name '*.diff' \) | sort -V > "$out_list"
  fi

  [[ -s "$out_list" ]] || fail "No patch files found in $src_dir"

  while IFS= read -r p; do
    [[ -f "$p" ]] || fail "Patch listed but missing: $p"
    validate_patch_header "$p"
  done < "$out_list"
}

apply_patch_file() {
  local p="$1"
  log "Applying: $p"

  if git am --3way --keep-cr "$p"; then
    return 0
  fi

  git am --abort >/dev/null 2>&1 || true

  if git apply --3way --index "$p"; then
    git commit -m "sukisu 3.x: apply $(basename "$p")"
    return 0
  fi

  fail "Conflict while applying patch: $p"
}

apply_patch_list() {
  local list_file="$1"
  while IFS= read -r p; do
    apply_patch_file "$p"
  done < "$list_file"
}

set_cfg_y() {
  local file="$1"
  local sym="$2"
  if grep -qE "^${sym}=y$" "$file"; then
    return 0
  fi

  if grep -qE "^# ${sym} is not set$" "$file"; then
    sed -i -E "s/^# ${sym} is not set$/${sym}=y/" "$file"
  elif grep -qE "^${sym}=" "$file"; then
    sed -i -E "s/^${sym}=.*/${sym}=y/" "$file"
  else
    echo "${sym}=y" >> "$file"
  fi
}

set_cfg_n() {
  local file="$1"
  local sym="$2"
  if grep -qE "^# ${sym} is not set$" "$file"; then
    return 0
  fi

  if grep -qE "^${sym}=" "$file"; then
    sed -i -E "s/^${sym}=.*/# ${sym} is not set/" "$file"
  else
    echo "# ${sym} is not set" >> "$file"
  fi
}

enable_required_config() {
  [[ -f "$CONFIG_FILE" ]] || fail "Config file not found: $CONFIG_FILE"

  log "Applying required config symbols"
  if [[ -x scripts/config ]]; then
    scripts/config --file "$CONFIG_FILE" -e CONFIG_KSU -e CONFIG_KPM -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL
    if [[ "$ENABLE_SUSFS" == "1" ]]; then
      scripts/config --file "$CONFIG_FILE" -e CONFIG_KSU_SUSFS
    else
      scripts/config --file "$CONFIG_FILE" -d CONFIG_KSU_SUSFS
    fi
  else
    set_cfg_y "$CONFIG_FILE" CONFIG_KSU
    set_cfg_y "$CONFIG_FILE" CONFIG_KPM
    set_cfg_y "$CONFIG_FILE" CONFIG_KALLSYMS
    set_cfg_y "$CONFIG_FILE" CONFIG_KALLSYMS_ALL
    if [[ "$ENABLE_SUSFS" == "1" ]]; then
      set_cfg_y "$CONFIG_FILE" CONFIG_KSU_SUSFS
    else
      set_cfg_n "$CONFIG_FILE" CONFIG_KSU_SUSFS
    fi
  fi

  log "Running olddefconfig"
  make olddefconfig
}

enable_minimal_bpf_if_supported() {
  local syms=(CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_HAVE_EBPF_JIT)

  for s in "${syms[@]}"; do
    if rg -n "^config ${s#CONFIG_}\\b" -g 'Kconfig*' kernel net lib init arch >/dev/null 2>&1; then
      log "Enabling supported BPF symbol: $s"
      if [[ -x scripts/config ]]; then
        scripts/config --file "$CONFIG_FILE" -e "$s" || true
      else
        set_cfg_y "$CONFIG_FILE" "$s"
      fi
    else
      log "Skipping unsupported BPF symbol: $s"
    fi
  done

  make olddefconfig
}

write_manual_hook_checklist() {
  local out="sukisu_manual_hooks_checklist_3x.txt"
  cat > "$out" <<'CHK'
# Manual hook checklist for kernel 3.x (apply only if stable in your tree)
# Rule: place hook before final side-effect path and preserve original errno/return flow.

# Cred hooks (search and patch manually)
# rg -n "commit_creds|prepare_kernel_cred|security_" kernel/ security/

# Exec hooks
# rg -n "do_execve|search_binary_handler|bprm_" fs/ kernel/

# Proc hooks
# rg -n "proc_create|proc_ops|file_operations|proc_fops" fs/ kernel/

# Mount/path hooks
# rg -n "do_mount|sys_mount|path_lookupat|user_path_at|vfs_kern_mount" fs/ kernel/

# SUSFS hooks are optional/risky on 3.x. Keep disabled if boot reliability regresses.
CHK

  git add "$out"
  git commit -m "docs: add 3.x manual hook checklist"
}

write_optional_notes() {
  mkdir -p Documentation
  cat > Documentation/sukisu_ultra_3x_optional_notes.txt <<'NOTE'
# Optional feature notes for SukiSU Ultra on kernel 3.x
# - CONFIG_KSU_SUSFS is optional; disable if boot stability drops.
# - Enable only BPF symbols that exist in this tree; skip unsupported eBPF features.
NOTE
  git add Documentation/sukisu_ultra_3x_optional_notes.txt
  git commit -m "docs: add optional SUSFS/BPF notes"
}

anti_bootloop_checks() {
  log "Validating mandatory configs"
  rg -n "^CONFIG_KSU=y$|^CONFIG_KPM=y$|^CONFIG_KALLSYMS=y$|^CONFIG_KALLSYMS_ALL=y$" "$CONFIG_FILE" >/dev/null || fail "Required config symbols missing"

  if [[ "$ENABLE_SUSFS" == "1" ]]; then
    rg -n "^CONFIG_KSU_SUSFS=y$" "$CONFIG_FILE" >/dev/null || fail "SUSFS requested but not enabled"
  fi
}

maybe_build_check() {
  if [[ "$SKIP_BUILD" == "1" ]]; then
    warn "Skipping build check (SKIP_BUILD=1)"
    return 0
  fi
  log "Running build check"
  make -j"$(nproc)" 2>&1 | tee /tmp/sukisu_ultra_3x_build.log
}

main() {
  require_cmd git
  require_cmd sed
  require_cmd find
  require_cmd rg
  require_cmd make

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "Run inside kernel git tree"
  require_clean_tree

  START_COMMIT="$(git rev-parse HEAD)"
  log "START_COMMIT=$START_COMMIT"

  log "Cloning official patch repositories"
  git clone --depth=1 "$PATCH_REPO_BASE" "$WORKDIR/SukiSU_patch"
  git clone --depth=1 "$PATCH_REPO_KP" "$WORKDIR/SukiSU_KernelPatch_patch"

  log "Building deterministic patch lists + header validation"
  build_patch_list "$WORKDIR/SukiSU_patch" "$WORKDIR/base.list"
  build_patch_list "$WORKDIR/SukiSU_KernelPatch_patch" "$WORKDIR/kp.list"

  log "Applying patch list: base -> kernel-patch"
  apply_patch_list "$WORKDIR/base.list"
  apply_patch_list "$WORKDIR/kp.list"

  enable_required_config
  enable_minimal_bpf_if_supported

  write_manual_hook_checklist
  write_optional_notes

  anti_bootloop_checks
  maybe_build_check

  log "Generating output diff: $OUT_DIFF"
  git diff "$START_COMMIT"..HEAD > "$OUT_DIFF"

  log "Done"
  log "Output: $OUT_DIFF"
  log "Rollback: git reset --hard $START_COMMIT && git clean -fd"
}

main "$@"
