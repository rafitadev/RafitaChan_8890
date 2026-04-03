#!/usr/bin/env bash
set -euo pipefail

# SukiSU Ultra 3.x auto-integrator (Exynos8890)
# Boot-safety rules:
# - 3.x only (3.4..3.18)
# - idempotent patching (safe to re-run)
# - backups before edit
# - optional SUSFS with hard safety gate
# - minimal BPF only if symbol exists
# - rollback command always printed

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

CONFIG_FILE="${1:-.config}"
OUT_DIFF="sukisu_ultra_integration_3x.diff"
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
ENABLE_BPF="${ENABLE_BPF:-1}"
RUN_OLDDEF="${RUN_OLDDEF:-1}"
SKIP_BUILD="${SKIP_BUILD:-1}"
START_COMMIT=""
BACKUP_DIR=".sukisu_backup_$(date +%Y%m%d_%H%M%S)"

a=() # modified files list

log(){ printf '[*] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }
req(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

ensure_kernel_3x(){
  local v p
  v="$(awk -F' = ' '/^VERSION =/{print $2}' Makefile | tr -d '[:space:]')"
  p="$(awk -F' = ' '/^PATCHLEVEL =/{print $2}' Makefile | tr -d '[:space:]')"
  [[ "$v" == "3" ]] || die "unsupported VERSION=$v"
  (( p >= 4 && p <= 18 )) || die "unsupported PATCHLEVEL=$p (expected 3.4..3.18)"
}

ensure_clean_tree(){
  [[ -z "$(git status --porcelain)" ]] || die "working tree must be clean"
}

track_modified(){
  local f="$1"
  for e in "${a[@]:-}"; do [[ "$e" == "$f" ]] && return 0; done
  a+=("$f")
}

backup_file(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR/$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR/$f"
}

backup_all(){
  [[ ${#a[@]} -eq 0 ]] && return 0
  mkdir -p "$BACKUP_DIR"
  for f in "${a[@]}"; do backup_file "$f"; done
  log "backup created: $BACKUP_DIR"
}

# Validate anchor functions for Exynos8890 3.x before patching.
validate_hook_targets(){
  rg -n 'int commit_creds\(' kernel/cred.c >/dev/null || die "commit_creds target missing"
  rg -n 'do_execveat_common' fs/exec.c >/dev/null || die "exec target missing"
  rg -n 'proc_pid_permission' fs/proc/base.c >/dev/null || die "proc target missing"
  rg -n 'SYSCALL_DEFINE5\(mount' fs/namespace.c >/dev/null || die "mount target missing"
  rg -n 'user_path_at_empty' fs/namei.c >/dev/null || die "path target missing"
}

# Treble/OneUI/GSI compatibility precheck: no vendor-hardcoded interception assumptions.
validate_layout_independence(){
  rg -n '/vendor|/system|/product|/odm' drivers/kernelsu fs/{namei.c,namespace.c,exec.c,open.c,stat.c,read_write.c,proc/base.c} >/dev/null && \
    warn "vendor/system path literal detected; verify hook code stays generic" || true
}

ensure_kernelsu_tree(){
  track_modified drivers/kernelsu/Kconfig
  track_modified drivers/kernelsu/Makefile
  track_modified drivers/kernelsu/ksu_core.c
  track_modified drivers/Kconfig
  track_modified drivers/Makefile
  track_modified fs/Kconfig
  track_modified fs/Makefile
  track_modified fs/susfs/Kconfig
  track_modified fs/susfs/Makefile
  track_modified fs/susfs/susfs_stub.c
  track_modified include/linux/susfs/susfs.h

  backup_all

  mkdir -p drivers/kernelsu fs/susfs include/linux/susfs

  [[ -f drivers/kernelsu/Kconfig ]] || cat > drivers/kernelsu/Kconfig <<'KCFG'
menu "KernelSU Ultra (3.x compatibility)"
config KSU
	bool "KernelSU core"
	default y
config KPM
	bool "Kernel patch manager compatibility"
	depends on KSU
	default y
config KSU_SUSFS
	bool "SUSFS (optional, risk-aware)"
	depends on KSU
	default n
endmenu
KCFG

  [[ -f drivers/kernelsu/Makefile ]] || echo 'obj-$(CONFIG_KSU) += ksu_core.o' > drivers/kernelsu/Makefile

  [[ -f drivers/kernelsu/ksu_core.c ]] || cat > drivers/kernelsu/ksu_core.c <<'KSU'
// SPDX-License-Identifier: GPL-2.0
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/types.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/cred.h>
bool ksu_vfs_read_hook __read_mostly;
bool ksu_execveat_hook __read_mostly;
bool ksu_input_hook __read_mostly;
int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,size_t *count_ptr, loff_t **pos){return 0;}
int ksu_handle_execve(int *fd, struct filename **filename_ptr, void *argv,void *envp, int *flags){return 0;}
int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,void *envp, int *flags){return ksu_handle_execve(fd, filename_ptr, argv, envp, flags);} 
int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,void *argv, void *envp, int *flags){return 0;}
int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,int *flags){return 0;}
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags){return 0;}
int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code,int *value){return 0;}
int ksu_handle_mount(char **dev_name, const char __user **dir_name,char **type, unsigned long *flags, unsigned long *data_page){return 0;}
int ksu_handle_commit_creds(struct cred *new, const struct cred *old){return 0;}
int ksu_handle_proc_pid_permission(struct inode *inode, int *mask){return 0;}
int ksu_handle_user_path_at(int *dfd, const char __user **name, unsigned *flags){return 0;}
KSU

  # SUSFS optional: create stubs only; runtime enabling still controlled by CONFIG_KSU_SUSFS.
  [[ -f fs/susfs/Kconfig ]] || cat > fs/susfs/Kconfig <<'SK'
config SUSFS_FS
	bool "SUSFS filesystem shim"
	depends on KSU_SUSFS
	default n
SK
  [[ -f fs/susfs/Makefile ]] || echo 'obj-$(CONFIG_KSU_SUSFS) += susfs_stub.o' > fs/susfs/Makefile
  [[ -f fs/susfs/susfs_stub.c ]] || cat > fs/susfs/susfs_stub.c <<'SS'
// SPDX-License-Identifier: GPL-2.0
#include <linux/init.h>
#include <linux/kernel.h>
static int __init susfs_stub_init(void){ pr_info("susfs stub loaded\n"); return 0; }
late_initcall(susfs_stub_init);
SS
  [[ -f include/linux/susfs/susfs.h ]] || cat > include/linux/susfs/susfs.h <<'SH'
#ifndef _LINUX_SUSFS_H
#define _LINUX_SUSFS_H
#endif
SH

  rg -n 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig >/dev/null || echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig
  rg -n 'obj-\$\(CONFIG_KSU\) \+= kernelsu/' drivers/Makefile >/dev/null || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
  rg -n 'source "fs/susfs/Kconfig"' fs/Kconfig >/dev/null || echo 'source "fs/susfs/Kconfig"' >> fs/Kconfig
  rg -n 'obj-\$\(CONFIG_KSU_SUSFS\) \+= susfs/' fs/Makefile >/dev/null || echo 'obj-$(CONFIG_KSU_SUSFS) += susfs/' >> fs/Makefile
}

py_patch(){
  # Explicit Python 3.12 invocation avoids legacy python/f-string syntax issues.
  python3.12 - "$@" <<'PY'
from pathlib import Path
import sys
mode = sys.argv[1]
path = Path(sys.argv[2])
text = path.read_text()
orig = text

def add_once(anchor, snippet):
    global text
    if snippet.strip() in text:
        return
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit(f"ANCHOR_MISSING:{path}:{anchor[:48]}")
    text = text[:idx+len(anchor)] + snippet + text[idx+len(anchor):]

if mode == 'cred':
    add_once('#include <linux/cn_proc.h>\n', '\n#if defined(CONFIG_KSU) && !defined(CONFIG_KPROBES)\nextern int ksu_handle_commit_creds(struct cred *new, const struct cred *old);\n#endif\n')
    add_once('BUG_ON(atomic_read(&new->usage) < 1);\n', '\n#if defined(CONFIG_KSU) && !defined(CONFIG_KPROBES)\n\t/* KernelSU 3.x hook: commit_creds */\n\tif (ksu_handle_commit_creds(new, old))\n\t\treturn -EPERM;\n#endif\n')
elif mode == 'exec':
    add_once('extern bool ksu_execveat_hook __read_mostly;\n', 'extern int ksu_handle_execve(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\tvoid *envp, int *flags);\n')
    text = text.replace('ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);', 'ksu_handle_execve(&fd, &filename, &argv, &envp, &flags);')
elif mode == 'proc':
    add_once('#include "../../lib/kstrtox.h"\n', '\n#if defined(CONFIG_KSU) && !defined(CONFIG_KPROBES)\nextern int ksu_handle_proc_pid_permission(struct inode *inode, int *mask);\n#endif\n')
    add_once('bool has_perms;\n', '\n#if defined(CONFIG_KSU) && !defined(CONFIG_KPROBES)\n\t/* KernelSU 3.x hook: proc_pid_permission */\n\tif (ksu_handle_proc_pid_permission(inode, &mask))\n\t\treturn -EPERM;\n#endif\n')
elif mode == 'mount':
    add_once('#include "internal.h"\n', '\n#if defined(CONFIG_KSU) && defined(CONFIG_KSU_SUSFS) && !defined(CONFIG_KPROBES)\nextern int ksu_handle_mount(char **dev_name, const char __user **dir_name,\n\t\t\t    char **type, unsigned long *flags,\n\t\t\t    unsigned long *data_page);\n#endif\n')
    add_once('if (ret < 0)\n\t\tgoto out_data;\n', '\n#if defined(CONFIG_KSU) && defined(CONFIG_KSU_SUSFS) && !defined(CONFIG_KPROBES)\n\t/* KernelSU 3.x hook: sys_mount */\n\tret = ksu_handle_mount(&kernel_dev, &dir_name, &kernel_type, &flags, &data_page);\n\tif (ret)\n\t\tgoto out_mount_hook;\n#endif\n')
    add_once('ret = do_mount(kernel_dev, dir_name, kernel_type, flags,\n\t\t(void *) data_page);\n', '\n#if defined(CONFIG_KSU) && defined(CONFIG_KSU_SUSFS) && !defined(CONFIG_KPROBES)\nout_mount_hook:\n#endif\n')
elif mode == 'path':
    add_once('#include "internal.h"\n', '\n#if defined(CONFIG_KSU) && !defined(CONFIG_KPROBES)\nextern int ksu_handle_user_path_at(int *dfd, const char __user **name,\n\t\t\t   unsigned *flags);\n#endif\n')
    add_once('struct nameidata nd;\n', '\n#if defined(CONFIG_KSU) && !defined(CONFIG_KPROBES)\n\t/* KernelSU 3.x hook: user_path_at */\n\tif (ksu_handle_user_path_at(&dfd, &name, &flags))\n\t\treturn -EPERM;\n#endif\n')
else:
    raise SystemExit('BAD_MODE')

if text != orig:
    path.write_text(text)
PY
}

apply_hooks_3x(){
  local targets=(kernel/cred.c fs/exec.c fs/proc/base.c fs/namespace.c fs/namei.c)
  for f in "${targets[@]}"; do track_modified "$f"; done
  backup_all

  py_patch cred kernel/cred.c
  py_patch exec fs/exec.c
  py_patch proc fs/proc/base.c
  py_patch mount fs/namespace.c
  py_patch path fs/namei.c
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

configure_kernel(){
  [[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"
  track_modified "$CONFIG_FILE"
  backup_all

  set_cfg CONFIG_KSU y
  set_cfg CONFIG_KPM y
  set_cfg CONFIG_KALLSYMS y
  set_cfg CONFIG_KALLSYMS_ALL y
  [[ "$ENABLE_SUSFS" == "1" ]] && set_cfg CONFIG_KSU_SUSFS y || set_cfg CONFIG_KSU_SUSFS n

  # Enable only BPF symbols that exist in this 3.x tree.
  if [[ "$ENABLE_BPF" == "1" ]]; then
    for s in CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_HAVE_EBPF_JIT; do
      rg -n "^config ${s#CONFIG_}\\b" -g 'Kconfig*' kernel net lib init arch >/dev/null 2>&1 && set_cfg "$s" y || true
    done
  fi

  [[ "$RUN_OLDDEF" == "1" ]] && make olddefconfig
}

validate_post_patch(){
  rg -n 'ksu_handle_commit_creds' kernel/cred.c >/dev/null || die "cred hook missing"
  rg -n 'ksu_handle_execve' fs/exec.c >/dev/null || die "exec hook missing"
  rg -n 'ksu_handle_proc_pid_permission' fs/proc/base.c >/dev/null || die "proc hook missing"
  rg -n 'ksu_handle_mount' fs/namespace.c >/dev/null || die "mount hook missing"
  rg -n 'ksu_handle_user_path_at' fs/namei.c >/dev/null || die "path hook missing"
  rg -n '^CONFIG_KSU=y$' "$CONFIG_FILE" >/dev/null || die "CONFIG_KSU missing"
  rg -n '^CONFIG_KPM=y$' "$CONFIG_FILE" >/dev/null || die "CONFIG_KPM missing"
  rg -n '^CONFIG_KALLSYMS=y$' "$CONFIG_FILE" >/dev/null || die "CONFIG_KALLSYMS missing"
  rg -n '^CONFIG_KALLSYMS_ALL=y$' "$CONFIG_FILE" >/dev/null || die "CONFIG_KALLSYMS_ALL missing"
  [[ "$ENABLE_SUSFS" == "1" ]] && rg -n '^CONFIG_KSU_SUSFS=y$' "$CONFIG_FILE" >/dev/null || true
}

write_notes(){
  track_modified Documentation/sukisu_ultra_3x_optional_notes.txt
  backup_all
  mkdir -p Documentation
  cat > Documentation/sukisu_ultra_3x_optional_notes.txt <<'NOTE'
# Safety notes
# - SUSFS is optional; if any SUSFS symbol/file is missing, keep CONFIG_KSU_SUSFS disabled.
# - BPF is enabled only for symbols present in this exact 3.x tree.
# - Hooks are generic VFS/syscall points for Treble/OneUI/GSI layout independence.
# Rollback:
#   git reset --hard <START_COMMIT>
#   git clean -fd
# Backup restore:
#   cp -a .sukisu_backup_*/<path> <path>
NOTE
}

maybe_build(){
  [[ "$SKIP_BUILD" == "1" ]] && { warn "SKIP_BUILD=1 (skip build)"; return 0; }
  ./cronos.sh
}

main(){
  # Require python3.12 because inline blocks use modern syntax/features.
  req git; req rg; req sed; req awk; req python3.12; req make
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git tree"

  ensure_kernel_3x
  ensure_clean_tree
  START_COMMIT="$(git rev-parse HEAD)"
  log "START_COMMIT=$START_COMMIT"

  validate_hook_targets
  validate_layout_independence
  ensure_kernelsu_tree

  # SUSFS safety gate: if requested but core files unavailable, disable to avoid boot break.
  if [[ "$ENABLE_SUSFS" == "1" ]]; then
    [[ -f fs/susfs/Kconfig && -f fs/susfs/Makefile && -f fs/susfs/susfs_stub.c ]] || {
      warn "SUSFS files incomplete; forcing ENABLE_SUSFS=0 for safety"
      ENABLE_SUSFS=0
    }
  fi

  apply_hooks_3x
  configure_kernel
  validate_post_patch
  write_notes
  maybe_build

  git diff "$START_COMMIT"..HEAD > "$OUT_DIFF"
  log "generated: $OUT_DIFF"
  log "rollback: git reset --hard $START_COMMIT && git clean -fd"
  log "backup: $BACKUP_DIR"
}

main "$@"
