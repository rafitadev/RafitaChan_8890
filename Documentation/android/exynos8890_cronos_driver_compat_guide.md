# Exynos8890 + Cronos: Massive Driver Update & Compatibility Guide

## Scope

Target devices: `herolte`, `hero2lte`, `gracelte/gracer`.
Build flow: `cronos.sh`.

This guide separates:
- **already integrated code paths** (Pageboost, fingerprint boost, GPU R30P0 path),
- **safe low-risk driver-level tuning** (GIC/MIF/cpuidle/HWC),
- **Cronos compile compatibility** steps.

---

## 1) Driver updates (performance / low-latency)

### 1.1 IRQ Chip & GIC

Current tree already includes low-latency oriented priority pattern updates in `irq-gic-common.c`.

Recommended validation after build:
```sh
rg -n "GICD_INT_LOWLAT|priority" drivers/irqchip/irq-gic-common.c
```

Runtime verification:
```sh
dmesg | grep -i -E "gic|irq"
```

### 1.2 DMC / Memory governor (MIF/INT)

The MIF devfreq path is the right place for app-open boost behavior in this tree.
Use existing MIF table tuning plus runtime script application.

Suggested runtime checks:
```sh
cat /sys/class/devfreq/*mif*/cur_freq
cat /sys/class/devfreq/*int*/cur_freq
```

### 1.3 Low-power C-states wake latency

For 8890, keep cpuidle enabled but avoid aggressive deep-idle preference during heavy UI sessions.
Do not disable cpuidle globally.

Recommended strategy:
- keep cpuidle drivers unchanged for stability,
- use SchedTune/core_ctl/input boost to reduce visible wake delay.

### 1.4 HWC/DECON path stability for blur/transparency

DECON thread priority and logging guards should remain enabled as already patched.
Validation:
```sh
rg -n "SCHED_FIFO|update_regs_thread|vsync" drivers/video/fbdev/exynos/decon_8890
```

---

## 2) Cronos compatibility analysis

## 2.1 Prior optimizations compatibility matrix

- **Pageboost**: Compatible with Cronos; controlled by defconfig + `/sys/kernel/pageboost/*`.
- **OC CPU 2.7 / GPU 806**: Build-time compatible; runtime stability depends on ASV bin.
- **Fingerprint 4-core boost**: Compatible; uses interactive governor hooks and module params.
- **Sched boost**: Compatible when SchedTune nodes exist at runtime.

## 2.2 Injecting compile flags with Cronos

Use env injection before calling `cronos.sh`:
```sh
export KCFLAGS="-O3 -mcpu=exynos-m1 -mtune=exynos-m1 -fgraphite-identity -floop-block"
# Optional aggressive (test carefully):
# export KCFLAGS="$KCFLAGS -Ofast -fno-math-errno -funsafe-math-optimizations"
bash cronos.sh
```

If Cronos exports `KBUILD_CFLAGS`, append instead of replacing:
```sh
export KBUILD_CFLAGS="$KBUILD_CFLAGS -O3 -mcpu=exynos-m1 -mtune=exynos-m1"
```

LTO note:
- For this 3.18 tree, avoid full LTO unless toolchain+linker path is fully validated.

---

## 3) Security/stability for weak silicon (ASV low bins)

For low-bin chips:
- Keep IPA and thermal control active.
- Keep ASV guardbands for top OPPs.
- Use staged rollout:
  1. baseline clocks,
  2. enable fingerprint/touch boosts,
  3. enable OC only after thermal soak.

Recommended acceptance criteria:
- 30 min UI stress (no freeze/reboot)
- 20 min camera + gallery + multitask (no LMK thrash)
- 15 min gaming (no blackscreen/artifacts)

---

## 4) Final hero_defconfig block

Apply to `hero_defconfig` / `exynos8890_defconfig` equivalent:

```config
# Core scheduling/governor
CONFIG_SCHED_TUNE=y
CONFIG_SCHED_WALT=y
CONFIG_CPU_FREQ_GOV_INTERACTIVE=y
CONFIG_HOTPLUG_CPU=y

# GPU / memory
CONFIG_MALI_R30P0=y
CONFIG_ZRAM=y
CONFIG_ZRAM_LZ4_COMPRESS=y
CONFIG_CMA=y
CONFIG_CMA_SIZE_SEL_MBYTES=y
CONFIG_CMA_SIZE_MBYTES=128

# Pageboost (full backport)
CONFIG_SAMSUNG_PAGEBOOST=y
CONFIG_PAGEBOOST_IO_BOOST=y
# CONFIG_PAGEBOOST_DEBUG is not set

# Filesystems
CONFIG_F2FS_FS=y
CONFIG_F2FS_FS_XATTR=y
CONFIG_F2FS_FS_POSIX_ACL=y
CONFIG_F2FS_FS_SECURITY=y

# Loop/APEX readiness
CONFIG_BLK_DEV_LOOP=y
CONFIG_BLK_DEV_LOOP_MIN_COUNT=64

# Workqueue power profile
CONFIG_WQ_POWER_EFFICIENT_DEFAULT=y

# Thermal / IPA
CONFIG_CPU_THERMAL=y
CONFIG_EXYNOS_THERMAL=y
CONFIG_EXYNOS_THERMAL_V2=y
CONFIG_EXYNOS_THERMAL_CORE=y
CONFIG_CPU_THERMAL_IPA=y

# Debug-overhead removal
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_LOCKDEP is not set
# CONFIG_SCHED_DEBUG is not set
# CONFIG_FTRACE is not set
# CONFIG_KPROBES is not set
# CONFIG_PROFILING is not set
# CONFIG_SEC_DEBUG is not set
# CONFIG_SEC_DEBUG_LAST_KMSG is not set
# CONFIG_KNOX_KAP is not set
# CONFIG_RKP_KDP is not set
# CONFIG_TIMA is not set
```

---

## 5) Runtime profile hook

Use:
```sh
sh scripts/oneui_optimization_pack.sh
```

This applies stune/core_ctl/input boost/block/binder/runtime VM profile for One UI.
