# Exynos8890 Samsung Optimization Pack (One UI)

This repository now contains an implementation-oriented pack focused on One UI performance.

## 1) Pageboost (full backport)

Backported component:
- `drivers/staging/samsung/pageboost.c`
- `drivers/staging/samsung/Kconfig`
- `drivers/staging/samsung/Makefile`

Defconfig:
```config
CONFIG_SAMSUNG_PAGEBOOST=y
CONFIG_PAGEBOOST_IO_BOOST=y
# CONFIG_PAGEBOOST_DEBUG is not set
```

Runtime enablement:
```sh
sh scripts/oneui_optimization_pack.sh
```

## 2) S-Boost / Touch Boost (minor hooks + runtime)

Existing interactive governor boost paths are used.
Key runtime knobs are set by `scripts/oneui_optimization_pack.sh`:
- `input_boost_duration=120000`
- `input_boost_freq_big=2002000`
- `input_boost_freq_little=1404000`

## 3) Fingerprint 4-core boost

Implemented in `drivers/cpufreq/cpufreq_interactive.c` using:
- `fingerprint_boost_4core_max=1` runtime default in script
- big cluster goes to max during fingerprint boost pulse

## 4) F2FS optimization path (no full subsystem backport)

Applied strategy:
- Keep F2FS core unchanged to avoid ABI/regression risk on 3.18.
- Prefer runtime + mount tuning for SQLite-heavy usage.

Recommended mount options:
- `inline_xattr,inline_data,flush_merge,background_gc=on`

## 5) Audio/Sound Boost

Small safe hardware gain headroom increase applied:
- `sound/soc/codecs/moro_sound.h`: `SPEAKER_MAX` from `63` to `66`.

This enables ~+3 to +5 dB class headroom depending on mixer path calibration.

## 6) Ultimate defconfig + scheduler

Reference file:
- `arch/arm64/configs/exynos8890_hero_defconfig.fragment`

Recommended block:
```config
CONFIG_SCHED_TUNE=y
CONFIG_SCHED_WALT=y
CONFIG_CPU_FREQ_GOV_INTERACTIVE=y
CONFIG_SAMSUNG_PAGEBOOST=y
CONFIG_PAGEBOOST_IO_BOOST=y
CONFIG_ZRAM=y
CONFIG_ZRAM_LZ4_COMPRESS=y
CONFIG_CMA=y
CONFIG_CMA_SIZE_SEL_MBYTES=y
CONFIG_CMA_SIZE_MBYTES=128
CONFIG_HZ_300=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_RCU_BOOST=y

# overhead removal
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_LOCKDEP is not set
# CONFIG_SCHED_DEBUG is not set
# CONFIG_FTRACE is not set
# CONFIG_KPROBES is not set
# CONFIG_PROFILING is not set
# CONFIG_SEC_DEBUG is not set
# CONFIG_KNOX_KAP is not set
# CONFIG_RKP_KDP is not set
```

## 7) IPC/Binder optimization (minor)

No risky binder core backport was added.
Production runtime profile sets:
- `/sys/module/binder/parameters/stop_on_user_error=0`

Additionally, block queue merge/iostat overhead is reduced via script for app launch responsiveness.

## Apply order

1. Merge this tree.
2. Ensure defconfig includes Pageboost and performance block.
3. Install `scripts/oneui_optimization_pack.sh` in init service (post-fs-data).
4. Reboot and validate with UI frame-time and app-open benchmarks.
