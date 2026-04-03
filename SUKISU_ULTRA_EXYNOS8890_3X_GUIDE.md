# SukiSU Ultra 3.x (Exynos8890) Safe Integration — Commands Only

## 1) Prepare clean workspace + restore point

```bash
cd /workspace/RafitaChan_8890                                 # enter kernel tree
git rev-parse --is-inside-work-tree                            # verify git repo
git status --porcelain                                          # must be empty before integration
START_COMMIT=$(git rev-parse HEAD)                             # pre-integration restore point
git checkout -b sukisu-ultra-3x-safe                           # isolated branch
mkdir -p /tmp/sukisu_ultra_3x                                  # temp workspace
```

## 2) Download official patch sources

```bash
cd /tmp/sukisu_ultra_3x                                         # temp dir
git clone --depth=1 https://github.com/SukiSU-Ultra/SukiSU_patch
git clone --depth=1 https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch
```

## 3) Build deterministic patch lists + header validation (stop on invalid files)

```bash
cd /workspace/RafitaChan_8890
find /tmp/sukisu_ultra_3x/SukiSU_patch -type f \( -name '*.patch' -o -name '*.diff' \) | sort -V > /tmp/sukisu_base.list
find /tmp/sukisu_ultra_3x/SukiSU_KernelPatch_patch -type f \( -name '*.patch' -o -name '*.diff' \) | sort -V > /tmp/sukisu_kp.list

# Validate mail-style or unified diff headers; stop on malformed patch
while IFS= read -r p; do
  (grep -qE '^(From [0-9a-f]{7,40}|diff --git )' "$p") || { echo "Invalid patch header: $p"; exit 1; }
done < /tmp/sukisu_base.list

while IFS= read -r p; do
  (grep -qE '^(From [0-9a-f]{7,40}|diff --git )' "$p") || { echo "Invalid patch header: $p"; exit 1; }
done < /tmp/sukisu_kp.list
```

## 4) Apply patches in deterministic order (base first, kernel-patch second)

```bash
# Base patches
while IFS= read -r p; do
  echo "[BASE] $p"
  git am --3way --keep-cr "$p" || {
    git am --abort || true
    git apply --3way --index "$p" || { echo "Conflict: $p"; exit 1; }
    git commit -m "SukiSU base 3.x: $(basename "$p")"
  }
done < /tmp/sukisu_base.list

# KernelPatch patches
while IFS= read -r p; do
  echo "[KP] $p"
  git am --3way --keep-cr "$p" || {
    git am --abort || true
    git apply --3way --index "$p" || { echo "Conflict: $p"; exit 1; }
    git commit -m "SukiSU kp 3.x: $(basename "$p")"
  }
done < /tmp/sukisu_kp.list
```

## 5) Manual hook map (3.x-safe locations)

```bash
# Cred hooks
rg -n "commit_creds|prepare_kernel_cred|security_" kernel/ security/

# Exec hooks
rg -n "do_execve|search_binary_handler|bprm_" fs/ kernel/

# Proc hooks
rg -n "proc_create|proc_ops|file_operations|proc_fops" fs/ kernel/

# Mount/path hooks
rg -n "do_mount|sys_mount|path_lookupat|user_path_at|vfs_kern_mount" fs/ kernel/
```

```bash
# For each hook insertion point: enforce guarded entry/exit pattern
# 1) insert before final side-effect path
# 2) wrap with CONFIG_KSU / CONFIG_KSU_SUSFS
# 3) preserve original errno semantics
# 4) skip hook if function signature mismatch causes unstable path
```

## 6) SUSFS decision gate (recommended: disable unless required)

```bash
# Path A (stable default): do NOT enable SUSFS
ENABLE_SUSFS=0

# Path B (optional/risky): enable SUSFS only if your tree boots reliably with it
# ENABLE_SUSFS=1
```

```bash
if [ "${ENABLE_SUSFS}" = "1" ]; then
  mkdir -p fs/susfs include/linux                               # create SUSFS dirs if missing
  grep -q 'susfs/' fs/Makefile || echo 'obj-$(CONFIG_KSU_SUSFS) += susfs/' >> fs/Makefile
  grep -q 'source "fs/susfs/Kconfig"' fs/Kconfig || echo 'source "fs/susfs/Kconfig"' >> fs/Kconfig
  rg -n "do_mount|sys_mount|vfs_kern_mount" fs/ kernel/        # confirm mount hook points exist
fi
```

## 7) Minimal BPF for 3.x only (no unnecessary features)

```bash
CFG=.config

# Detect BPF symbols supported by this kernel tree
rg -n "^config (BPF|BPF_SYSCALL|BPF_JIT|HAVE_EBPF_JIT)\b" -g 'Kconfig*' kernel/ net/ lib/ init/ arch/

# Enable only if symbol exists in Kconfig
for s in CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_HAVE_EBPF_JIT; do
  if rg -n "^config ${s#CONFIG_}\b" -g 'Kconfig*' >/dev/null; then
    if [ -x scripts/config ]; then scripts/config --file "$CFG" -e "$s"; else sed -i -E "s/^# ${s} is not set$/${s}=y/; t; s/^${s}=.*/${s}=y/; t; \$a${s}=y" "$CFG"; fi
  fi
done
```

## 8) Required kernel config (minimal + SUSFS conditional)

```bash
CFG=.config

# Required always
if [ -x scripts/config ]; then
  scripts/config --file "$CFG" -e CONFIG_KSU -e CONFIG_KPM -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL
else
  for s in CONFIG_KSU CONFIG_KPM CONFIG_KALLSYMS CONFIG_KALLSYMS_ALL; do
    sed -i -E "s/^# ${s} is not set$/${s}=y/; t; s/^${s}=.*/${s}=y/; t; \$a${s}=y" "$CFG"
  done
fi

# SUSFS only when explicitly enabled
if [ "${ENABLE_SUSFS}" = "1" ]; then
  if [ -x scripts/config ]; then scripts/config --file "$CFG" -e CONFIG_KSU_SUSFS; else sed -i -E "s/^# CONFIG_KSU_SUSFS is not set$/CONFIG_KSU_SUSFS=y/; t; s/^CONFIG_KSU_SUSFS=.*/CONFIG_KSU_SUSFS=y/; t; \$aCONFIG_KSU_SUSFS=y" "$CFG"; fi
else
  if [ -x scripts/config ]; then scripts/config --file "$CFG" -d CONFIG_KSU_SUSFS; else sed -i -E "s/^CONFIG_KSU_SUSFS=.*/# CONFIG_KSU_SUSFS is not set/" "$CFG"; fi
fi

make olddefconfig                                                    # normalize dependencies
```

## 9) Bootloop/stability checks before full build

```bash
# Required configs present
rg -n "^CONFIG_KSU=y$|^CONFIG_KPM=y$|^CONFIG_KALLSYMS=y$|^CONFIG_KALLSYMS_ALL=y$" .config

# SUSFS status confirmation
if [ "${ENABLE_SUSFS}" = "1" ]; then rg -n "^CONFIG_KSU_SUSFS=y$" .config; else rg -n "^# CONFIG_KSU_SUSFS is not set$" .config; fi

# Hook symbol presence check (adjust token names to actual integrated code)
rg -n "CONFIG_KSU|ksu_|susfs_handle_mount|KSU_SUSFS" fs/ kernel/ security/ include/

# Dry compile early fail-fast
make -j"$(nproc)" 2>&1 | tee /tmp/sukisu_ultra_3x_build.log
```

## 10) Generate final diff with optional feature notes

```bash
# Add inline notes as comments into a tracked note file so they appear in diff
cat > Documentation/sukisu_ultra_3x_optional_notes.txt <<'NOTE'
# Optional feature notes:
# - CONFIG_KSU_SUSFS is optional on kernel 3.x; disable when boot stability regresses.
# - BPF options are limited to symbols present in this tree; do not force unsupported eBPF features.
NOTE

git add Documentation/sukisu_ultra_3x_optional_notes.txt
git commit -m "docs: add optional SUSFS/BPF stability notes for 3.x"

git diff "$START_COMMIT"..HEAD > sukisu_ultra_integration_3x.diff       # required output file
```

## 11) Rollback and recovery

```bash
# Abort in-progress am session
git am --abort || true

# Revert all working tree changes
git reset --hard

# Return to pre-integration commit
git reset --hard "$START_COMMIT"

# Remove untracked files
git clean -fd

# Remove temporary download workspace
rm -rf /tmp/sukisu_ultra_3x
```
