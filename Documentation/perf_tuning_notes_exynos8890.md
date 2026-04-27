# Exynos 8890 performance tuning notes

This document tracks low-risk tuning areas for Exynos 8890-based devices.
It is intentionally conservative and intended to help contributors split work into
small, reviewable changes.

## Scope

- Prioritize frame-time consistency and input responsiveness.
- Keep memory reclaim behavior predictable under One UI workloads.
- Avoid broad subsystem rewrites when a focused knob change is enough.

## Candidate areas

1. Memory reclaim / boosting
   - Prefer small, reversible knob additions.
   - Preserve existing behavior as default unless device testing justifies a new default.

2. ZRAM defaults
   - Validate stream count against CPU topology.
   - Prefer compression algorithms already supported by the tree config.

3. F2FS background work
   - Defer expensive background activity during active user interaction where practical.

4. Scheduler and input boost integration
   - Keep boost windows short and measurable.
   - Avoid hard forcing max frequency in generic input paths.

5. Lowmemorykiller defaults
   - Tune for foreground stability first.
   - Document test conditions for any minfree/adj changes.

## Validation checklist

- [ ] `make ARCH=arm64 exynos8890_defconfig`
- [ ] Build-test modified objects/subsystems.
- [ ] Capture before/after interaction latency traces.
- [ ] Verify no regressions in background app retention.
