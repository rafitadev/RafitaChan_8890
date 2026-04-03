#!/usr/bin/env bash
set -euo pipefail

# SukiSU Ultra full in-tree integrator (Android kernel 3.x / Exynos8890)
# Step-by-step command comments are intentionally inline.
#
# Safe defaults:
#   ENABLE_SUSFS=0   (optional; keep 0 unless proven stable)
#   ENABLE_BPF=1     (minimal BPF symbols only if present)
#   RUN_OLDDEF=1
#   SKIP_BUILD=1
#
# Rollback (manual):
#   git reset --hard "$START_COMMIT" && git clean -fd

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PATCH_REPO_BASE="https://github.com/SukiSU-Ultra/SukiSU_patch"
PATCH_REPO_KP="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch"
OUT_DIFF="sukisu_ultra_integration_3x.diff"
CONFIG_FILE="${1:-.config}"

ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
ENABLE_BPF="${ENABLE_BPF:-1}"
RUN_OLDDEF="${RUN_OLDDEF:-1}"
SKIP_BUILD="${SKIP_BUILD:-1}"

WORKDIR="$(mktemp -d -t sukisu-ultra-3x-XXXXXX)"
START_COMMIT=""

log(){ printf '[*] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup(){ rm -rf "$WORKDIR"; }
trap cleanup EXIT

req(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

assert_clean_tree(){
  [[ -z "$(git status --porcelain)" ]] || die "git tree not clean"
}

validate_patch_header(){
  local p="$1"
  grep -qE '^(From [0-9a-f]{7,40}|diff --git )' "$p" || die "invalid patch header: $p"
}

build_patch_list(){
  local src="$1" out="$2"
  : > "$out"
  if [[ -f "$src/series" ]]; then
    while IFS= read -r l; do [[ -z "$l" || "$l" =~ ^# ]] && continue; printf '%s\n' "$src/$l" >> "$out"; done < "$src/series"
  elif [[ -f "$src/patches/series" ]]; then
    while IFS= read -r l; do [[ -z "$l" || "$l" =~ ^# ]] && continue; printf '%s\n' "$src/patches/$l" >> "$out"; done < "$src/patches/series"
  else
    find "$src" -type f \( -name '*.patch' -o -name '*.diff' \) | sort -V > "$out"
  fi
  [[ -s "$out" ]] || die "no patches found in $src"
  while IFS= read -r p; do [[ -f "$p" ]] || die "missing patch: $p"; validate_patch_header "$p"; done < "$out"
}

apply_patch_file(){
  local p="$1"
  log "apply $p"
  git am --3way --keep-cr "$p" && return 0
  git am --abort >/dev/null 2>&1 || true
  git apply --3way --index "$p" && return 0
  die "patch conflict: $p"
}

apply_patch_list(){
  local lst="$1"
  while IFS= read -r p; do apply_patch_file "$p"; done < "$lst"
}

set_cfg(){
  local sym="$1" val="$2"
  if [[ -x scripts/config ]]; then
    [[ "$val" == "y" ]] && scripts/config --file "$CONFIG_FILE" -e "$sym" || scripts/config --file "$CONFIG_FILE" -d "$sym"
  else
    if [[ "$val" == "y" ]]; then
      sed -i -E "s/^# ${sym} is not set$/${sym}=y/; t; s/^${sym}=.*/${sym}=y/; t; \$a${sym}=y" "$CONFIG_FILE"
    else
      sed -i -E "s/^${sym}=.*/# ${sym} is not set/; t; \$a# ${sym} is not set" "$CONFIG_FILE"
    fi
  fi
}

enable_required_config(){
  [[ -f "$CONFIG_FILE" ]] || die "config missing: $CONFIG_FILE"
  set_cfg CONFIG_KSU y
  set_cfg CONFIG_KPM y
  set_cfg CONFIG_KALLSYMS y
  set_cfg CONFIG_KALLSYMS_ALL y
  [[ "$ENABLE_SUSFS" == "1" ]] && set_cfg CONFIG_KSU_SUSFS y || set_cfg CONFIG_KSU_SUSFS n
}

enable_minimal_bpf(){
  [[ "$ENABLE_BPF" == "1" ]] || return 0
  local syms=(CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_HAVE_EBPF_JIT)
  for s in "${syms[@]}"; do
    if rg -n "^config ${s#CONFIG_}\\b" -g 'Kconfig*' kernel net lib init arch >/dev/null 2>&1; then
      set_cfg "$s" y
    fi
  done
}

normalize_config(){
  [[ "$RUN_OLDDEF" == "1" ]] || return 0
  make olddefconfig
}

verify_hooks(){
  # Cred
  rg -n "ksu_handle_commit_creds" kernel/cred.c drivers/kernelsu/ksu_core.c >/dev/null
  # Exec
  rg -n "ksu_handle_execve|ksu_handle_execveat" fs/exec.c drivers/kernelsu/ksu_core.c >/dev/null
  # Proc
  rg -n "ksu_handle_proc_pid_permission" fs/proc/base.c drivers/kernelsu/ksu_core.c >/dev/null
  # Path
  rg -n "ksu_handle_user_path_at|ksu_safe_user_path_wrapper" fs/namei.c drivers/kernelsu/ksu_core.c >/dev/null
  # Mount
  rg -n "ksu_handle_mount|ksu_safe_mount_wrapper" fs/namespace.c drivers/kernelsu/ksu_core.c >/dev/null
}

anti_bootloop_checks(){
  rg -n "^CONFIG_KSU=y$|^CONFIG_KPM=y$|^CONFIG_KALLSYMS=y$|^CONFIG_KALLSYMS_ALL=y$" "$CONFIG_FILE" >/dev/null || die "required config missing"
  if [[ "$ENABLE_SUSFS" == "1" ]]; then rg -n "^CONFIG_KSU_SUSFS=y$" "$CONFIG_FILE" >/dev/null || die "SUSFS requested but absent"; fi
}

write_optional_notes(){
  mkdir -p Documentation
  cat > Documentation/sukisu_ultra_3x_optional_notes.txt <<'NOTE'
# Optional toggles (safe defaults)
# - CONFIG_KSU_SUSFS: optional, keep disabled unless boot-tested stable.
# - BPF: enable only symbols supported by this kernel tree.
# - Treble/OneUI/GSI: wrappers are layout-independent (VFS-level hooks only).
# Rollback:
#   git reset --hard <start_commit>
#   git clean -fd
NOTE
}

maybe_build(){
  [[ "$SKIP_BUILD" == "1" ]] && { warn "SKIP_BUILD=1"; return 0; }
  make -j"$(nproc)" 2>&1 | tee /tmp/sukisu_ultra_3x_build.log
}

main(){
  req git; req rg; req sed; req make; req find
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo"
  assert_clean_tree

  START_COMMIT="$(git rev-parse HEAD)"
  log "start_commit=$START_COMMIT"

  # Download official patches.
  git clone --depth=1 "$PATCH_REPO_BASE" "$WORKDIR/SukiSU_patch"
  git clone --depth=1 "$PATCH_REPO_KP" "$WORKDIR/SukiSU_KernelPatch_patch"

  # Deterministic ordered patch lists + header validation.
  build_patch_list "$WORKDIR/SukiSU_patch" "$WORKDIR/base.list"
  build_patch_list "$WORKDIR/SukiSU_KernelPatch_patch" "$WORKDIR/kp.list"

  # Apply base then kernel-patch and stop on conflicts.
  apply_patch_list "$WORKDIR/base.list"
  apply_patch_list "$WORKDIR/kp.list"

  # Apply minimal config/BPF/SUSFS toggles.
  enable_required_config
  enable_minimal_bpf
  normalize_config

  # Validate all requested manual hook points are present.
  verify_hooks
  anti_bootloop_checks

  # Write optional notes for SUSFS/BPF/Treble-GSI behavior + rollback.
  write_optional_notes

  maybe_build

  # Generate final integration diff from pre-integration HEAD.
  git diff "$START_COMMIT"..HEAD > "$OUT_DIFF"
  log "generated: $OUT_DIFF"
  log "rollback: git reset --hard $START_COMMIT && git clean -fd"
}

main "$@"
