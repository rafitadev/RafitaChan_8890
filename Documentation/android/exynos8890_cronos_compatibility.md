# Exynos8890 + Cronos (`cronos.sh`) — atualização de drivers, compatibilidade e defconfig final

## 1) Atualização de drivers adicionais (performance/low-latency)

> Objetivo: manter compatibilidade com kernel 3.18 e evitar regressões em build/boot.

### 1.1 IRQ Chip / GIC
- **Escopo seguro para 3.18**:
  - priorizar *thread affinity* das IRQs de display/input/GPU para CPUs big em carga de UI;
  - reduzir seções críticas em handlers que fazem trabalho pesado (mover para workqueues);
  - revisar prioridades de interrupções de display/DSI para reduzir jitter de frame.
- **Risco**: mudanças profundas no GIC podem afetar estabilidade de modem/câmera e latências de wakeup.
- **Recomendação**: aplicar otimizações de afinidade e pipeline primeiro, sem reescrever controlador IRQ.

### 1.2 DMC / Devfreq (boost agressivo na abertura de apps)
- No tree atual, já existe stack de devfreq e governor Exynos, além de `CONFIG_MALI_DEVFREQ` e govs devfreq habilitados.
- Plano seguro:
  - elevar lock mínimo de MIF/INT por janela curta na abertura de app (80–300ms), sincronizado com `input/fingerprint boost`;
  - manter fallback térmico via IPA para evitar runaway.

### 1.3 Low Power C-States (wake mais rápido)
- Ajuste recomendado: reduzir permanência em estados mais profundos durante interação (janela curta pós-input), mantendo estados profundos em idle sustentado.
- Importante: não remover cpuidle profundo globalmente (impacto térmico/bateria).

### 1.4 HWC/Display path (60 FPS OneUI)
- Melhorias de latência devem ficar no caminho de DECON/DSI e prioridades de worker/vsync (já existentes no tree), sem hacks que desalinhem fencing.
- Priorizar estabilidade de pacing de frame em vez de subir clocks fixos continuamente.

---

## 2) Compatibilidade com `cronos.sh`

### 2.1 Como o script gera configuração
- O script concatena `hero_defconfig` + (`oneui_defconfig` ou `treble_defconfig`) + `cronos_defconfig` em `tmp_defconfig` antes do build.
- Também injeta flags opcionais (SELinux permissive, hall reverse, KernelSU, etc.) no `tmp_defconfig`.

### 2.2 Conflitos com otimizações passadas
- **Pageboost**: compatível se `CONFIG_SAMSUNG_PAGEBOOST=y` e `CONFIG_PAGEBOOST_IO_BOOST=y`.
- **OC 2.7GHz (big)**: não há evidência de símbolo Kconfig dedicado no tree; depende de tabelas DVFS/ASV e não apenas defconfig.
- **GPU 806MHz**: depende da tabela DVFS do driver (`gpu_exynos8890.c`), não de um único `CONFIG_`.
- **Fingerprint/Sched Boost**: alguns símbolos pedidos em mensagens anteriores não existem neste tree; usar hooks existentes em `cpufreq_interactive` + HMP + sysfs runtime.

### 2.3 Como injetar flags no ambiente Cronos
- O `Makefile` principal já suporta `KCFLAGS` (`KBUILD_CFLAGS += $(KCFLAGS)`), então pode-se injetar direto no `cronos.sh`.
- Exemplo (conservador):
  - `export KCFLAGS="-O3 -mcpu=exynos-m1 -mtune=exynos-m1 -fgraphite-identity -floop-block -floop-interchange"`
- Exemplo (agressivo/teste):
  - `export KCFLAGS="-Ofast -mcpu=exynos-m1 -mtune=exynos-m1 -fgraphite-identity -floop-block"`
- **Recomendação**: evitar LTO em 3.18 legado sem validação completa de toolchain, para reduzir risco de link/runtime regressions.

---

## 3) Segurança/estabilidade (silício fraco)

- Para silício com ASV ruim, **não** considerar “estabilidade total” com OC agressivo sem validação em hardware.
- Segurança operacional para daily:
  - manter `CONFIG_CPU_THERMAL_IPA=y` e `CONFIG_CPU_THERMAL_IPA_CONTROL=y`;
  - usar steps de frequência graduais (evitar salto sustentado no topo);
  - validar throttling real com stress combinado (CPU+GPU+UFS).
- Se houver reboot/WDT em carga longa: reduzir OC big e/ou aumentar headroom de voltagem apenas nos OPPs de topo.

---

## 4) Bloco final de `CONFIG_...` para `hero_defconfig` (OneUI 4.1 foco estabilidade + performance)

```config
# Scheduler / CPU
CONFIG_HOTPLUG_CPU=y
CONFIG_CPU_FREQ_GOV_INTERACTIVE=y
CONFIG_SCHED_TUNE=y
CONFIG_SCHED_WALT=y

# Thermal safety
CONFIG_CPU_THERMAL=y
CONFIG_CPU_THERMAL_IPA=y
CONFIG_CPU_THERMAL_IPA_CONTROL=y
# CONFIG_CPU_THERMAL_IPA_DEBUG is not set

# GPU stack (R30P0)
CONFIG_MALI_T8XX=y
CONFIG_MALI_R30P0=y
CONFIG_MALI_DVFS=y
CONFIG_MALI_DEVFREQ=y
CONFIG_MALI_RT_PM=y
CONFIG_MALI_MIDGARD=y
CONFIG_MALI_SEC_CL_BOOST=y
CONFIG_MALI_PM_QOS=y
CONFIG_MALI_BTS_OPTIMIZATION=y

# Memory / IO
CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND=y
CONFIG_DEVFREQ_GOV_SIMPLE_EXYNOS=y
CONFIG_ZRAM=y
CONFIG_ZRAM_LZ4_COMPRESS=y
# CONFIG_ZRAM_WRITEBACK is not set
CONFIG_CMA=y
CONFIG_CMA_SIZE_SEL_MBYTES=y
CONFIG_CMA_SIZE_MBYTES=128
CONFIG_F2FS_FS=y
CONFIG_F2FS_FS_SECURITY=y

# Pageboost
CONFIG_SAMSUNG_PAGEBOOST=y
CONFIG_PAGEBOOST_IO_BOOST=y

# Debug overhead reduction
# CONFIG_SEC_DEBUG is not set
# CONFIG_SEC_DEBUG_LAST_KMSG is not set
# CONFIG_KNOX_KAP is not set
# CONFIG_RKP_KDP is not set
# CONFIG_PROFILING is not set
# CONFIG_FTRACE is not set
# CONFIG_TIMA is not set
```

### Símbolos solicitados que **não existem** no tree atual (necessitam backport real de Kconfig/código)
- `CONFIG_ALLOW_4_CORES_MAX_FREQ`
- `CONFIG_CPU_FREQ_LIMIT_START_FREQ`
- `CONFIG_CPU_BOOST`, `CONFIG_CPU_BOOST_FREQ`
- `CONFIG_FINGERPRINT_BOOST`, `CONFIG_TOUCHSCREEN_BOOST`
- `CONFIG_PAGEBOOST_PREFETCH`
- `CONFIG_SCHED_BOOST`
- `CONFIG_EXYNOS_ASV`, `CONFIG_EXYNOS_OV_UV`
- `CONFIG_MALI_BIFROST_FOR_SW_DEVELOPER`, `CONFIG_MALI_GONDUL_LATE_DVFS`, `CONFIG_EXYNOS_DEVFREQ_HIERARCHY`

---

## 5) Resposta objetiva: “terá estabilidade total para uso diário?”

- **Não posso garantir estabilidade total** com OC agressivo (2.7GHz big + tuning agressivo de GPU/voltagem) sem validação em dispositivo real por horas/dias.
- Com o bloco acima (foco em thermal IPA + throttling controlado + zRAM/F2FS/Pageboost), a chance de estabilidade para daily é **boa**, mas ainda depende da loteria de silício, bateria e temperatura ambiente.
