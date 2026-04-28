# Ramdisk init.perftune.rc Integration (Install-and-Go)

## 1) Files

- `ramdisk/init.perftune.rc` (property-driven app launch detection)
- `scripts/app_launch_boost.sh` (kernel knob executor)

## 2) init.perftune.rc behavior

- Watches `sys.perf.launch` property.
- If package is one of:
  - `com.ss.android.ugc.trill`
  - `com.instagram.android`
  - `com.whatsapp`
  then starts corresponding launch boost service.
- Service calls `app_launch_boost.sh` which applies:
  - `launch_boostpulse=1`
  - `surfaceflinger_boostpulse=1`
  - dynamic `read_ahead_kb` (`4096` for heavy apps / `2048` fallback)
  - compact/writeback launch profile

## 3) Boot image bundling instructions

Because this kernel tree does not contain device-specific Android mkbootimg packaging,
integrate via your device build system:

### A. Copy files into ramdisk/vendor ramdisk
```make
# device/<vendor>/<device>/BoardConfig.mk or device makefile
PRODUCT_COPY_FILES += \
    kernel/<path>/ramdisk/init.perftune.rc:$(TARGET_COPY_OUT_RAMDISK)/init.perftune.rc \
    kernel/<path>/scripts/app_launch_boost.sh:$(TARGET_COPY_OUT_VENDOR)/bin/app_launch_boost.sh
```

### B. Import in init
Add to your main init rc (device ramdisk):
```rc
import /init.perftune.rc
```

### C. Trigger from framework/perfd
Set property at app launch start:
```sh
setprop sys.perf.launch com.instagram.android
```

## 4) Defconfig hints

```config
CONFIG_SCHED_TUNE=y
CONFIG_SCHED_WALT=y
CONFIG_CPU_FREQ_GOV_INTERACTIVE=y
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y
CONFIG_IOSCHED_DEADLINE=y
# CONFIG_DEFAULT_CFQ is not set
CONFIG_DEFAULT_DEADLINE=y
CONFIG_DEFAULT_IOSCHED="deadline"
# CONFIG_PROFILING is not set
# CONFIG_FTRACE is not set
```

## 5) Notes

- `uclamp_min=100` requires scheduler uclamp support (not native in this 3.18 baseline).
  Use the launch boost pulse hooks as the practical equivalent.
- `CONFIG_MGLRU` is not available in this tree and needs deep mm backporting before use.
