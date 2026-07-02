# Exynos 8890 (3.18.x) – Plano massivo de atualização de drivers (herolte/hero2lte/grace/gracer)

> Objetivo: definir um roadmap de backport **executável por etapas** para elevar o kernel 3.18 a um perfil “moderno” para OneUI 4.1, sem introduzir regressões clássicas de API.

## Escopo de dispositivos

- `herolte` (S7)
- `hero2lte` (S7 Edge / N7FE ports)
- `gracelte` / `gracer` / `grace` family (Note 7 tree baseada em common)

## 1) Barramentos e Voltagens (ASV + Devfreq)

### Arquivos-alvo
- `drivers/soc/samsung/pwrcal/S5E8890/S5E8890-asv.c`
- `drivers/soc/samsung/pwrcal/S5E8890/S5E8890-dfs.c`
- `drivers/devfreq/*exynos*` (bus governor hooks)

### Patch-base recomendado (offset por binagem)
```c
/* exemplo de offset dinâmico por domínio/ASV group */
static int asv_uv_offset_cpu_big[16] = {
	0, -6250, -6250, -12500, -12500, -12500, -18750, -18750,
	-18750, -25000, -25000, -25000, -31250, -31250, -31250, -37500
};

static inline unsigned int apply_asv_uv_offset(unsigned int base_uv, int grp)
{
	int uv = (int)base_uv;
	if (grp < 0) grp = 0;
	if (grp > 15) grp = 15;
	uv += asv_uv_offset_cpu_big[grp];
	if (uv < 700000) uv = 700000; /* floor safety */
	return (unsigned int)uv;
}
```

### Diretriz
- Aplicar offset em OPPs de CPU/GPU/MIF/INT via ponto de montagem ASV.
- Limitar undervolt inicial a -25mV em produção e ampliar apenas após stress térmico/estabilidade.

---

## 2) UFS 2.0 (scsi/ufs) – backport 4.4+

### Arquivos-alvo
- `drivers/scsi/ufs/ufshcd.c`
- `drivers/scsi/ufs/ufshcd-pltfrm.c`
- `drivers/scsi/ufs/ufs-exynos.c`

### Diretriz de backport
- Portar primeiro melhorias de:
  - command queue depth handling
  - host reset/recovery path
  - HPB-like random I/O latency mitigations (quando existir no branch fonte)
- Evitar portar blocos acoplados a APIs de blk-mq mais novas sem camada de compatibilidade.

---

## 3) Display/Imagem (DECON + G2D + FIMC/IS)

### Arquivos-alvo
- `drivers/video/fbdev/exynos/decon_8890/*`
- `drivers/media/platform/exynos/fimg2d/*` (ou `video/exynos`)
- `drivers/media/platform/exynos/fimc-is2/*`

### Patch-base recomendado (prioridade de thread)
```c
/* decon worker/vsync prioridade RT estável para composições pesadas */
struct sched_param param = { .sched_priority = 4 };
sched_setscheduler_nocheck(decon->update_regs_thread, SCHED_FIFO, &param);
```

### Diretriz
- Priorizar path de composição e reduzir wakeups redundantes no pipeline.
- Em FIMC/IS: reduzir clocks periféricos em idle para evitar drain em preview inativo.

---

## 4) Áudio low-latency (ASoC + Boeffla Sound)

### Arquivos-alvo
- `sound/soc/samsung/*`
- `sound/soc/codecs/cs47l91*` e rotas WM1810/WM1840 equivalentes
- `drivers/base/power/boeffla_wl_blocker.*` (integração eco no standby)

### Diretriz
- Backport de latência focado em:
  - menor period_size para playback interativo
  - redução de underruns em transições de power domain

---

## 5) Conectividade e sensores (bcmdhd / sensorhub / wacom)

### Arquivos-alvo
- `drivers/net/wireless/bcmdhd*`
- `drivers/sensorhub/*` (ou `drivers/stm/*` conforme árvore)
- `drivers/input/*wacom*`

### Diretriz
- bcmdhd: atualizar blobs+driver em par (fw + nvram + interface API).
- Sensorhub: aumentar janela de polling em standby e manter IRQ wake para proximidade.
- Wacom (grace/gracer): reduzir debounce no path de stylus-down e otimizar palm reject thresholds.

---

## 6) Thermal / IPA

### Arquivos-alvo
- `drivers/thermal/*`
- `drivers/soc/samsung/*thermal*`
- DTS térmico (`arch/arm64/boot/dts/exynos8890-*.dtsi`)

### Diretriz
- Manter `CONFIG_CPU_THERMAL_IPA=y` e ajustar budget por domínio (CPU/GPU/MIF).
- Preferir throttling gradual por power-budget em vez de steps abruptos.

---

## 7) Segurança e power loops

### Arquivos-alvo
- Defconfig + opções Samsung security
- `arch/arm64/configs/exynos8890_defconfig`

### Diretriz
- Manter desabilitado: `TIMA`, `RKP`, `SEC_DEBUG` em builds de performance.
- Ajustar `cpuidle` residency thresholds para retorno mais rápido de deep idle.

---

## Flags .defconfig (baseline recomendado)

```text
CONFIG_CPU_THERMAL_IPA=y
CONFIG_CPU_THERMAL_IPA_CONTROL=y
CONFIG_SCSI_UFSHCD=y
CONFIG_SCSI_UFS_EXYNOS=y
CONFIG_ARM64_EXYNOS_CPUIDLE=y
CONFIG_STORE_MODE=y
CONFIG_WQ_POWER_EFFICIENT_DEFAULT=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_BLK_DEV_LOOP_MIN_COUNT=64
# CONFIG_TIMA is not set
# CONFIG_TIMA_RKP is not set
# CONFIG_SEC_DEBUG is not set
```

## Checklist de rollout (obrigatório por variante)

1. `herolte`: validar câmera + áudio + modem + deep sleep.
2. `hero2lte`: validar thermal sustain em UI blur + jogos.
3. `grace/gracer`: validar SPen/Wacom + thermal charging.
4. Repetir stress test 30–60 min (CPU+GPU+I/O) antes de liberar offsets ASV agressivos.
