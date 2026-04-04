# RafitaChan Universal Kernel (Exynos 8890) - Performance/Treble Profile

## Objetivo
Este perfil foi ajustado para Galaxy S7 Edge Exynos (hero2lte/herolte family), focando em:
- Performance agressiva para OneUI, AOSP e GSI Treble.
- Overclock de big cluster com teto operacional em **3.016 GHz** (quando a tabela DVFS/ASV do dispositivo permitir).
- Menor stutter em I/O, UI e jogos.
- Preservação de thermal throttling e limites elétricos para reduzir risco de reboot térmico.

## O que foi alterado

### 1) CPU e scheduler
- Governor interactive ficou mais responsivo por padrão (subida mais rápida de clock e menor tempo de permanência em frequência alta antes de descer).
- Entradas de boost de rede (Argos) foram elevadas para permitir solicitações até 3.016 GHz no cluster big, melhorando bursts pesados de throughput.
- Tabela DVFS do cluster big em OneUI/Treble foi atualizada com entrada válida de **3016000 kHz** para que apps como CPU-Z/Kernel Manager detectem 3.016 GHz como frequência máxima quando este kernel estiver ativo.
- Tensão do degrau OC (L0 big) foi alinhada para **1325000 uV** para combinar com o fallback de OC no driver e melhorar estabilidade em chips com ASV mais fraco.

### 2) Memória e I/O
- Defconfig com I/O scheduler `noop` como padrão e `deadline` habilitado como alternativa.
- `F2FS` habilitado para melhor compatibilidade/performance em partições suportadas.
- Script runtime com ajustes VM (`dirty_ratio`, `swappiness`, cache pressure) e fila de bloco.

### 3) GPU
- Tabela DVFS do Mali ajustada para ramp-up mais agressivo.
- Clock máximo configurado para 806 MHz com thresholds mais orientados a carga pesada.
- Mantidas proteções térmicas com degraus de throttling para estabilidade em uso extremo.

### 4) Compatibilidade Treble
- Mudanças são no kernel genérico e em tabelas comuns herolte/gracelte, sem remover drivers essenciais.
- Mantidos subsistemas críticos (modem interface, PM QoS, thermal e drivers base do firmware Samsung).

---

## Compilação automática
Use o script:

```bash
./scripts/build_universal_kernel.sh treble
# ou
./scripts/build_universal_kernel.sh oneui
# ou
./scripts/build_universal_kernel.sh stock
```

Variáveis úteis:
- `CROSS_COMPILE` (ex.: `aarch64-linux-android-`)
- `OUT_DIR` (default: `out`)
- `JOBS` (default: `nproc`)
- `DEFCONFIG` (pode ser exportado para sobrescrever o perfil automaticamente)

Artefato principal esperado:
- `out/arch/arm64/boot/Image.gz-dtb`

---

## Flash seguro (Heimdall)
> Faça backup completo antes. Bateria recomendada acima de 60%.

1. Reinicie em Download Mode.
2. Conecte via USB e confirme detecção:
   ```bash
   heimdall detect
   ```
3. Flasheie o boot image compatível com seu empacotamento (exemplo):
   ```bash
   heimdall flash --BOOT boot.img --no-reboot
   ```
4. Ao terminar, force reboot para recovery e limpe cache/dalvik se necessário.
5. Primeiro boot pode demorar vários minutos.

## Flash seguro (Odin)
1. Empacote `boot.img`/`tar.md5` conforme layout da ROM.
2. Abra Odin (AP slot), desative *Auto Reboot* para controle manual.
3. Flash e, ao concluir, entre direto em recovery para limpar cache.
4. Reinicie o sistema.

---

## Pós-flash recomendado
- Rodar como root:
  ```bash
  su -c sh /path/para/scripts/runtime_tune_universal.sh
  ```
- Aplicar esse script no boot (Magisk service.d) se desejar perfil persistente.
- Em caso de aquecimento excessivo, reduza `scaling_max_freq` do cluster big para 2808000.
- Verificação de detecção em apps/CLI:
  ```bash
  cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_available_frequencies
  cat /sys/devices/system/cpu/cpu4/cpufreq/cpuinfo_max_freq
  ```

---

## Riscos e aviso importante
- Overclock e uso extremo **podem causar** aquecimento, degradação de bateria/SoC e perda de estabilidade.
- Nem todo chip Exynos 8890 sustenta 3.016 GHz continuamente (variação de silício/ASV).
- Se houver bootloop ou kernel panic, restaure kernel anterior via Download Mode.
