# SukiSU-Ultra update guide (Exynos8890 / kernel 3.18 / Cronos)

## 1) Git commands to update to latest upstream

### A) If `drivers/kernelsu` is a git submodule
```bash
git submodule set-url drivers/kernelsu https://github.com/SukiSU-Ultra/SukiSU-Ultra.git
git submodule update --init --remote drivers/kernelsu
git -C drivers/kernelsu fetch --tags
git -C drivers/kernelsu checkout "$(git -C drivers/kernelsu tag --sort=-v:refname | head -n1)"
```

### B) If `drivers/kernelsu` is a plain folder
```bash
# from kernel root
bash scripts/update_sukisu_ultra.sh
```

### Compatibility requirements to keep for 3.18
- keep `path_umount` fallback/backport glue (`kernel_umount.c` / `KSU_HAS_PATH_UMOUNT`)
- keep `vfs_statx` compatibility wrappers (if present in your branch)
- keep `ktime_get_coarse_real_ts64` compatibility wrappers (if present in your branch)

---

## 2) Android 12+/OneUI 4.1 mount namespace fixes

Your tree does not use `ksu.c` + `hooks.c` names; the equivalent mount/hook logic here is:
- `drivers/kernelsu/su_mount_ns.c`
- `drivers/kernelsu/kernel_umount.c`
- `drivers/kernelsu/syscall_handler.c`

Applied hardening in this repo:
- skip namespace switching for kernel threads or tasks without fs/nsproxy context.
- skip `umount` attempts for APEX/loop-critical mounts (`/apex`, `/system/apex`, `/linkerconfig`, `/mnt/loop`).
- reduce hook log spam when `CONFIG_KSU_DEBUG=n`.

---

## 3) Cronos integration

`scripts/cronos_prebuild_tune.sh` now enforces:
- `CONFIG_KSU=y`
- `# CONFIG_KSU_DEBUG is not set`

Run before build:
```bash
bash scripts/update_sukisu_ultra.sh
bash scripts/cronos_prebuild_tune.sh
bash cronos.sh
```

---

## 4) OC non-interference check (2.7GHz big / 806MHz GPU)

KernelSU update must not touch DVFS/ASV/GPU tables. Validate quickly:
```bash
rg -n "2704000|1716000" drivers/soc/samsung/pwrcal/S5E8890/
rg -n "\{806, 875000|GPU_MAX_CLOCK_LIMIT, 806" drivers/gpu/arm/t8xx/r30p0/platform/exynos/gpu_exynos8890.c
```

---

## 5) Clean re-apply workflow script

Already provided as:
- `scripts/update_sukisu_ultra.sh`

It:
1. backups current `drivers/kernelsu`
2. removes stale January artifacts
3. updates from upstream
4. rechecks required 3.18 compatibility hooks
5. optionally reapplies `patches/sukisu_3.18_compat.patch` (if present)
