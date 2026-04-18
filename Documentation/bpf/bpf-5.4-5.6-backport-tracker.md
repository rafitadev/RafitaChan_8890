# BPF 5.4 → 5.6 Backport Tracker (Exynos8890 / 3.18 base)

## Context

This tree is based on Linux 3.18.140 with prior partial BPF backports. A direct 1:1 import of all Linux 5.4..5.6 BPF commits is **not** mechanically possible because multiple hard dependencies are missing in core mm, tracing, net, btf, and compiler support paths.

This tracker is used to perform **real** staged backports (no version spoofing, no fake UAPI exposure).

## Rules followed in this tracker

- No spoof of `LINUX_VERSION_CODE`, `utsname`, or fake capability bits.
- No UAPI enum/struct additions without backend support.
- No silent stubs.
- Each blocked item must include dependency and reason.

## Batch 0 (completed in this changeset)

### Defconfig hardening for BPF validation and tracing

Enabled for `arch/arm64/configs/exynos8890_defconfig`:

- `CONFIG_BPF_UNPRIV_DEFAULT_OFF=y`
- `CONFIG_BPF_JIT_ALWAYS_ON=y`
- `CONFIG_BPF_EVENTS=y`
- `CONFIG_KPROBE_EVENT=y`
- `CONFIG_UPROBE_EVENT=y`
- `CONFIG_FTRACE_SYSCALLS=y`

Rationale:

- aligns runtime with safer BPF defaults (unpriv BPF off by default)
- ensures BPF tracing hooks are available for verifier/helper regression testing
- improves observability for subsequent verifier/map/jit backport batches

## Mining and porting plan (next batches)

1. **Verifier core parity (highest impact)**
   - scalar bounds tracking refinements
   - alu32 correctness and edge-case pruning fixes
   - pointer arithmetic and min/max tracking hardening
2. **Map correctness and lifetime**
   - hash/LRU/percpu correctness fixes
   - refcount/lifetime fixes in map update/delete paths
3. **Helper semantics**
   - helper-side verifier contract updates
   - helper return-value range annotations where required
4. **sys_bpf and UAPI alignment**
   - only expose commands/fields with full kernel backend support
5. **Tracing/perf/cgroup integration**
   - verifier program-type specific constraints
   - perf event and trace attach path fixes
6. **arm64 JIT safety pass**
   - JIT correctness and constant blinding parity where portable

## Known hard blockers already identified

- BTF-dependent 5.6 paths that require modern BTF/type-id infra absent in this 3.18 base.
- Later `struct bpf_prog_info` / link-based UAPI expansions depending on newer object model not present in this tree.
- Some verifier precision fixes depend on post-4.x register state semantics and helper metadata that must be backported first.

These blockers are not skipped silently: each commit candidate must be marked as
- `ported`
- `adapted`
- `blocked (dependency)`

before closing the 5.4..5.6 backport effort.
