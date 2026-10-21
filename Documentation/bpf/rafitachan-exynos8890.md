# BPF no RafitaChan (Exynos 8890)

Documento sobre o estado real do BPF neste kernel. Escrito a partir da leitura
do código-fonte. **Nada aqui foi compilado nem testado em hardware.**

## 1. Base real

- Kernel: Linux **3.18.140** (`Makefile`), com um backport grande de eBPF
  (histórico: commits "Added Some Parts And Added Shiron BPF Thanks").
- Configuração compartilhada: `arch/arm64/configs/exynos8890_defconfig`
  (`CONFIG_BPF_SYSCALL`, `CONFIG_CGROUP_BPF`, `CONFIG_BPF_JIT`,
  `CONFIG_NET_CLS_BPF`, `CONFIG_NET_ACT_BPF`, `CONFIG_NETFILTER_XT_MATCH_BPF`,
  `CONFIG_SECCOMP_FILTER`). `hero2_defconfig` e `gracer_defconfig` são
  fragmentos por dispositivo e não repetem opções de BPF. Portanto herolte,
  hero2lte, gracelte e gracerlte já compartilham a mesma implementação.
  Nenhum defconfig foi alterado.

## 2. O que já existia (verificado no código)

- Syscall `bpf()` com `check_uarg_tail_zero`, `security_bpf` e
  `unprivileged_bpf_disabled`.
- Comandos: MAP_CREATE/LOOKUP/UPDATE/DELETE/GET_NEXT_KEY, PROG_LOAD, OBJ_PIN,
  OBJ_GET, PROG_ATTACH/DETACH/QUERY, GET_*_ID, OBJ_GET_INFO_BY_FD, BTF_LOAD.
- Mapas: hash, array, prog_array, perf_event_array, percpu hash/array,
  stack_trace, cgroup_array, LRU (e percpu), LPM trie, array/hash-of-maps,
  devmap.
- Programas: socket_filter, sched_cls, sched_act, xdp, cgroup_skb, cgroup_sock,
  cgroup_sock_addr, cgroup_sockopt, kprobe, tracepoint, perf_event.
- Helpers de rede usados pelo Android: `get_socket_cookie`, `get_socket_uid`,
  `ktime_get_boot_ns`, `skb_load_bytes(_relative)`, entre outros.
- JIT ARM64 com imagem somente-leitura, offset aleatório e `bpf_jit_limit`.
  Classic BPF e seccomp-BPF preservados.
- **Correção de uma afirmação anterior deste documento:** a API de blinding de
  constantes (`bpf_jit_blind_constants`) existia em `kernel/bpf/core.c`, mas o JIT
  ARM64 **não a chamava** e nenhum outro JIT da árvore a usa. Portanto
  `net.core.bpf_jit_harden` não tinha efeito. Isso foi corrigido na etapa 2.

## 3. Alterações desta branch (`rafitachan-bpf-hardening`)

| Arquivo | Mudança |
|---|---|
| `kernel/bpf/syscall.c` | `BPF_BTF_LOAD` exige `CAP_SYS_ADMIN` (como o upstream 4.19) e valida o cabeçalho do blob BTF (magic, versão, flags, limites, ordem e alinhamento das seções, seção de strings terminada em NUL). Antes aceitava qualquer blob de até 16 MB sem privilégio. |
| `kernel/bpf/hashtab.c` | `BPF_MAP_TYPE_DEVMAP_HASH` deixou de ser um hash genérico com outro nome: agora exige chave `u32` e valor `u32`, como no upstream. |
| `include/uapi/linux/bpf.h` | Comentário de `BPF_PROG_TEST_RUN` corrigido: o comando **não** está implementado (retorna `-EINVAL`). |

### Etapa 2 (branch `rafitachan-bpf-6.6-backport`): JIT ARM64

| Arquivo | Mudança |
|---|---|
| `arch/arm64/net/bpf_jit_comp.c` | **Tail call** (`BPF_JMP\|BPF_TAIL_CALL`) implementado no JIT, espelhando o interpretador: índice convertido para u32, comparação sem sinal com `max_entries`, limite `MAX_TAIL_CALL_CNT`, `prog == NULL`, salto para `bpf_func + PROLOGUE_OFFSET`. O frame é compartilhado e o SP é restaurado antes do salto. |
| `arch/arm64/net/bpf_jit_comp.c` | **Blinding de constantes** ligado: `bpf_int_jit_compile()` chama `bpf_jit_blind_constants()` e libera o clone com `bpf_jit_prog_release_other()`. `BPF_REG_AX` mapeado para `x9`; os registradores temporários do JIT foram movidos para `MAX_BPF_JIT_REG+n` porque `BPF_REG_AX == MAX_BPF_REG` colidia com `TMP_REG_1`. |
| `arch/arm64/net/bpf_jit_comp.c` | Layout de frame idêntico para todos os programas (condição do tail call): os `push/pop` dos temporários `x23/x24` agora são incondicionais. `x26`, que já era salvo no frame sem uso, virou `tail_call_cnt`. Prólogo e bloco de tail call verificam o próprio tamanho e, se divergirem, o JIT falha e o programa cai no interpretador. |
| `arch/arm64/net/bpf_jit.h` | Macro `A64_BR`. |

Custo conhecido: um `push/pop` extra por programa JITado (sempre salva `x23/x24`).

### Etapa 3 (branch `rafitachan-bpf-6.6-backport`): `BPF_JMP32` e saltos do JIT

| Arquivo | Mudança |
|---|---|
| `include/uapi/linux/bpf.h` | Classe `BPF_JMP32` (0x06). Só existe em eBPF; no classic BPF 0x06 continua sendo `BPF_RET` e nunca chega ao verificador eBPF. |
| `include/linux/filter.h` | Macros `BPF_JMP32_REG` e `BPF_JMP32_IMM`. |
| `kernel/bpf/core.c` | Interpretador: 22 handlers `JMP32_*` (comparam só os 32 bits baixos; os signed usam `s32`). `bpf_is_jmp_and_has_target()` reconhece JMP32, para o ajuste de offsets em patches. Blinding de constantes também cobre `JMP32 \| K`. |
| `kernel/bpf/verifier.c` | Aceita JMP32 em `do_check`, `check_cfg` e `check_cond_jmp_op`; rejeita `JA/CALL/EXIT` na classe JMP32. **Abordagem conservadora**: para JMP32 não há desvio estático, refinamento de limites, prova de ponteiro não-NULL nem inferência de pacote; os dois caminhos são sempre explorados com o estado intacto. Isso só pode rejeitar mais programas, nunca aceitar um inseguro. |
| `arch/arm64/net/bpf_jit_comp.c` | JMP32 em registradores `w`. Além disso, corrigidos dois buracos antigos do JIT: faltavam `JLT/JLE/JSLT/JSLE` e `JSET` (caía em `-EFAULT`); esses programas iam para o interpretador. |
| `arch/arm64/net/bpf_jit.h` | Condições `A64_COND_CC/LS/LT/LE`. |

Efeito prático: programas gerados por clang moderno (que usam `JLT/JLE/JSLT/JSLE`)
agora podem ser JITados no ARM64 em vez de cair no interpretador.

> Correção posterior (Etapa 4): na época desta etapa o verificador ainda
> rejeitava `JLT/JLE/JSLT/JSLE` (`opcode > BPF_EXIT`), então esses programas
> nem chegavam ao JIT. Isso foi corrigido na Etapa 4.

### Etapa 4: rastreamento de 32 bits no verificador atual e correção de ALU32

Base real do verificador: família Linux 4.9/4.13 (`CONST_IMM`/`UNKNOWN_VALUE`,
`min_value`/`max_value`, `imm` = bits superiores zero), com pedaços de eras
posteriores. **Não** tem `tnum` no estado do registrador. Portar o rework
`f1174f77b` (4.14) sobre essa base foi tentado e abandonado: 28 de 56 hunks
rejeitados, ~1900 linhas de `.rej`, por causa da base híbrida. Ver seção 4.

| Arquivo | Mudança |
|---|---|
| `include/linux/tnum.h`, `kernel/bpf/tnum.c`, `kernel/bpf/Makefile` | Biblioteca `tnum` do Linux 6.6 (inclui `tnum_subreg*`). **Ainda não usada pelo verificador.** Soundness de add/sub/and/or/xor/mul/range verificada por harness fora da árvore. |
| `kernel/bpf/verifier.c` | **Correção de segurança (classe do upstream 468f6eafa6c4)**: ALU32 calculava os limites em aritmética de 64 bits. Ex.: `w1 -= 3` com `w1∈[0,5]` dava `max=2`, mas o resultado real pode ser `0xFFFFFFFD`. Agora os operandos são limitados aos 32 bits baixos (`coerce_reg_to_32`) e o resultado só mantém limites se for totalmente limitado e não negativo. |
| `kernel/bpf/verifier.c` | Resultado de ALU32 é registrado com 32 bits superiores zero (`imm=32`). `w1 = w2` copia o estado quando `w2` cabe em 32 bits e é exato quando `w2` é constante. |
| `kernel/bpf/verifier.c` | `JLT/JLE/JSLT/JSLE` aceitos em JMP e JMP32, com refinamento de limites por equivalência (`a<v` é a negação de `a>=v`; `const<r` é `r>const`). |
| `kernel/bpf/verifier.c` | JMP32 entre duas constantes conhecidas: desvio decidido exatamente nos 32 bits baixos, só o caminho tomado é seguido. |
| `kernel/bpf/verifier.c` | JMP32 contra constante: o refinamento de limites de 64 bits é reutilizado **somente** se o registrador é provadamente limpo em 32 bits (cabe em `[0,2^32)`; `[0,2^31)` para comparações com sinal). Nunca se aplica fato dos 32 bits baixos ao registrador inteiro. |

Verificação (fora do kernel, sem compilá-lo): fuzz de 4M casos sobre o
`adjust_reg_min_max_vals` extraído do próprio arquivo, comparando com a
semântica concreta de 32 bits; o mesmo fuzz contra o código antigo reprova
(~350 contraexemplos). Força bruta de 3M casos para folding de JMP32,
equivalência "cabe em 32 bits ⇒ JMP32 ≡ JMP" e as identidades dos saltos
"menor que".

Limitações: não é o modelo de `u32_min/u32_max/s32_min/s32_max` do 6.6; a
aritmética de 32 bits só mantém limites sem overflow. O rastreamento de pacote
(`find_good_pkt_pointers`) ainda só entende `JGT/JGE`, não `JLT/JLE`.
**Nada disto foi compilado nem testado em aparelho.**

## 4. O que NÃO está implementado (limitações honestas)

- **BTF real**: o tipo de cada entrada não é interpretado. O shim existe só
  para o `NetBpfLoad` não abortar. Programas que dependem de verificação por BTF
  (funções globais, `func_info`) podem falhar no verificador.
- **DEVMAP_HASH real**: sem `bpf_redirect_map` nele; é só um hash u32→u32.
- **Verificador**: faltam chamadas bpf-to-bpf (`BPF_PSEUDO_CALL`), a mitigação de
  Spectre v4 (`sanitize_ptr_alu`) e o modelo completo de limites (`tnum` no
  estado do registrador, `u32_min/u32_max`). Há refinamento parcial de 32 bits
  (Etapa 4); o verificador continua sendo o estilo 4.9/4.13.
- **JIT ARM64**: tail call e blinding foram escritos **sem compilar nem testar**;
  sem BPF-to-BPF calls. O limite de pilha por tail call
  encadeado é o mesmo do interpretador (`MAX_TAIL_CALL_CNT`).
- Sem `BPF_MAP_TYPE_RINGBUF`, `BPF_F_MMAPABLE`, `clsact`, `BPF_PROG_TEST_RUN`.
  O loader do Android pula programas cujo `min_kver` é maior que o do kernel.
- **Requisito do Android**: o `NetBpfLoad` do Android V (15) em diante aborta
  se o kernel for menor que 4.19. Com `uname` real de 3.18 isso depende de
  ajuste no userspace (fora deste repositório).

## 5. Próximos passos sugeridos

1. Compilar e capturar o log do `NetBpfLoad`/`netd` para ver a próxima falha real.
2. Testar o JIT: carregar um programa com tail call e outro com `bpf_jit_harden=2`.
3. `sanitize_ptr_alu` no verificador, só com testes em dispositivo.
4. Parser BTF real, se algum programa exigir verificação por tipos.

### Etapa 4 (branch `rafitachan-bpf-android`): flags de acesso dos mapas

| Arquivo | Mudança |
|---|---|
| `include/uapi/linux/bpf.h` | `BPF_F_RDONLY_PROG` (1<<7) e `BPF_F_WRONLY_PROG` (1<<8), com os mesmos valores do upstream. |
| `include/linux/bpf.h` | `BPF_F_ACCESS_MASK`, `bpf_map_flags_to_cap()`, `bpf_map_flags_retain_permanent()`. |
| `kernel/bpf/{arraymap,hashtab,lpm_trie,devmap}.c` | Aceitam e **guardam** as flags (antes `hashtab` rejeitava `BPF_F_RDONLY/WRONLY` e `lpm_trie` nem gravava `map_flags`). Combinar `RDONLY_PROG`+`WRONLY_PROG` retorna `-EINVAL`. Devmaps (inclusive o tipo de compatibilidade `DEVMAP_HASH`) passam a ser `RDONLY_PROG` implicitamente, como no upstream. |
| `kernel/bpf/verifier.c` | `check_map_access_type()`: escrita em mapa `RDONLY_PROG` e leitura em `WRONLY_PROG` são rejeitadas (acesso direto, xadd e argumentos de helpers); `map_update_elem`/`map_delete_elem` rejeitados em mapa `RDONLY_PROG`. |
| `kernel/bpf/syscall.c` | `BPF_OBJ_GET_INFO_BY_FD` deixou de mascarar `map_flags` por tipo de mapa (antes: 128 fixo para `DEVMAP_HASH`, 1 fixo para `LPM_TRIE`); agora devolve o valor real do mapa. |

Não compilado nem testado em hardware.

### Etapa 5 (branch `rafitachan-bpf-android`): `BPF_MAP_FREEZE`

| Arquivo | Mudança |
|---|---|
| `include/uapi/linux/bpf.h` | `BPF_MAP_FREEZE = 22` (número do ABI upstream). Os números 19–21 continuam **não implementados**. |
| `include/linux/bpf.h` | `bpf_map.frozen` e `bpf_map.freeze_sem`. |
| `kernel/bpf/syscall.c` | `map_freeze()`: exige `CAP_SYS_ADMIN`, irreversível, `-EBUSY` se já congelado. `map_update_elem`/`map_delete_elem` seguram `freeze_sem` para leitura e retornam `-EPERM` em mapa congelado; o congelamento toma o semáforo para escrita, então nenhuma atualização em andamento escapa. `frozen:` aparece no fdinfo. |

Limitação: congelar só afeta a syscall. O acesso dos programas continua controlado por `BPF_F_RDONLY_PROG`; a otimização do upstream que trata leituras de mapa `RDONLY_PROG` congelado como constantes no verificador **não** foi portada. Não compilado nem testado em hardware.

### Etapa 6 (branch `rafitachan-bpf-6.6-backport`): `var_off` (tnum) no verificador

Referência upstream: `kernel/bpf/verifier.c` e `kernel/bpf/tnum.c` do Linux 6.6
(`adjust_scalar_min_max_vals`, `reg_bounds_sync`). Este verificador continua no estilo
4.9/4.13 (`CONST_IMM`/`UNKNOWN_VALUE` + `min_value`/`max_value`); não existe
`__mark_reg_known()`.

| Item | Estado |
|---|---|
| Campo `struct tnum var_off` em `bpf_reg_state`, inicializado como `tnum_unknown` | IMPLEMENTADO |
| `tnum_const()` em `MOV imm` (ALU64 com extensão de sinal, ALU32 com extensão por zero), `LD_IMM64` (analisador) e `CONST_IMM += K/X` | IMPLEMENTADO |
| Propagação em AND, OR, XOR, LSH, RSH, ARSH, ADD, SUB, MUL (imediato e registrador, ALU32 e ALU64), em `scalar_alu_var_off()` | IMPLEMENTADO |
| Deslocamento por registrador | PARCIAL: só com quantidade conhecida e menor que a largura; senão `tnum_unknown` |
| DIV, MOD, NEG, END | PARCIAL: resultado `tnum_unknown` (conservador) |
| MOV32 de registrador (constante conhecida, ou `tnum_cast(src, 4)`) | IMPLEMENTADO |
| JEQ/JNE: `var_off = tnum_const(val)` só no caminho de igualdade, só para `UNKNOWN_VALUE` | IMPLEMENTADO |
| Refinamento por JGT/JGE/JLT/..., JSET, limites derivados do tnum, `u32_min/u32_max` | PENDENTE |
| `states_equal()`: `var_off` **ignorado** na comparação exata (`reg_state_same_ignoring_var_off`) | IMPLEMENTADO |
| Uso de `var_off` em decisões de segurança (acesso a mapa/pacote, alinhamento) | PENDENTE, deliberadamente: nada lê `var_off` ainda |

Quando `var_off` passar a influenciar decisões, a comparação em `states_equal()` deve virar
`tnum_in(rold->var_off, rcur->var_off)`.

VERIFICADO ESTATICAMENTE (userspace, sem compilar o kernel): `tnum.c` e a função
`scalar_alu_var_off()` extraída do `verifier.c` foram compilados juntos e comparados com a
semântica concreta do interpretador em cerca de 20 milhões de pares aleatórios, sem nenhum
resultado fora do tnum calculado. `git diff --check` limpo.

NÃO TESTADO EM HARDWARE nem compilado como parte do kernel.

## Android GSI boot: what the kernel can and cannot fix

Findings from auditing the Android BPF loading path against this tree
(sources: AOSP `packages/modules/Connectivity`: `netbpfload/NetBpfLoad.cpp`,
`bpf/netd/BpfHandler.cpp`, `bpf_progs/netd.c`). Not tested on hardware.

### Userspace version gates (independent of any kernel feature)

The Android loaders compare the version reported by `uname` against a
per-release minimum and refuse to continue below it:

| Android | Minimum kernel enforced by loader |
|---------|-----------------------------------|
| 13 (T)  | 4.9                               |
| 14 (U)  | 4.14                              |
| 15 (V)  | 4.19                              |
| 16      | 5.4 (the check is written for the "25Q2" platform level) |

This kernel reports 3.18.140. Backporting BPF features cannot satisfy these
checks, and this project does not fake the version string or patch
userspace. Consequence: with an unmodified GSI, `netbpfload`/`bpfloader`
logs the "requires kernel X" error and exits before loading any program,
for all four releases. What init does next depends on the ROM's init.rc.
The BPF work below only matters once that gate is dealt with outside the
kernel by whoever builds the GSI.

### Kernel-side gaps found and fixed

* Helper IDs 4..8 differed from upstream (`probe_read`, `ktime_get_ns`,
  `trace_printk`, `get_prandom_u32`, `get_smp_processor_id`). Fixed; the
  remaining IDs were checked against the upstream table.
* `net/core/filter.c`: skb-only helpers were reachable from CGROUP_SOCK,
  CGROUP_SOCK_ADDR, CGROUP_SOCKOPT and XDP programs (wrong ctx type);
  `trace_printk` fell through into `get_socket_cookie`;
  SOCKET_FILTER lacked `skb_load_bytes`. Fixed via `bpf_base_func_proto()`.

### Checked and found present

BPF syscall commands used by the loader (map create/lookup/update/delete/
get_next_key, prog load, obj pin/get with file_flags, prog attach/detach/
query, *_GET_NEXT_ID, *_GET_FD_BY_ID, OBJ_GET_INFO_BY_FD), HASH/ARRAY and
per-CPU/LRU/LPM/devmap map types, bpffs (mkdir, rename, mode=), cgroup
attach for skb/sock/sock_addr/sockopt, `xt_bpf` pinned-object mode (rev 1),
BPF_XADD (verifier, interpreter, ARM64 JIT), `__sk_buff` layout up to
`gso_size`.

### Known gaps, not yet addressed

* ~~`expected_attach_type` accepted but not stored or validated~~ — fixed, see
  "CGROUP_SOCK_ADDR hardening" below.
* `struct bpf_sock` has only 6 fields (upstream has src/dst addr, ports,
  state, ...). Programs gated to KVER >= 4.14 are skipped by the Android
  loader on older kernels, so this is not a T-era blocker.
* No ring buffer, `BPF_PROG_TEST_RUN`, `BPF_RAW_TRACEPOINT_OPEN`.
  (`BPF_MAP_LOOKUP_AND_DELETE_ELEM` now exists for hash maps, see below.)

### CGROUP_SOCK_ADDR hardening and `expected_attach_type`

Found while auditing the attach path (static reading, nothing compiled or run
on a device):

| Item | Before | Now |
|---|---|---|
| `expected_attach_type` | accepted, dropped | validated at load for CGROUP_SOCK (0 is mapped to `INET_SOCK_CREATE`), CGROUP_SOCK_ADDR and CGROUP_SOCKOPT; stored in `struct bpf_prog`; `BPF_PROG_ATTACH` requires a match (CGROUP_SKB only if the loader set one). Other program types are unchanged. |
| `is_valid_access()` | no access to the program | takes `const struct bpf_prog *` (upstream 4.17 signature) |
| `sock_addr_is_valid_access()` | `return true` for any offset/size/direction | 4-byte aligned accesses inside `struct bpf_sock_addr` only; `user_ip4`/`user_ip6` per v4/v6 attach type; `msg_src_ip4/6` only for UDP4/UDP6 sendmsg; writes only to `user_ip4/6`, `user_port`, `msg_src_ip4/6` |
| `sock_addr_convert_ctx_access()` | 4-byte loads of 2-byte fields; IPv6 word index ignored | real field widths; `user_ip6[n]`/`msg_src_ip6[n]` hit word `n` |

Why it mattered: `convert_ctx_accesses()` only rewrites 4/8-byte LDX/STX, so the
old `return true` let 1/2-byte accesses reach `struct bpf_sock_addr_kern`
unrewritten (privileged programs only, CAP_SYS_ADMIN), and `msg_src_ip*` read the
NULL `t_ctx` outside UDP sendmsg.

Limitations: no narrow (1/2-byte) reads of `user_ip4/6` and no 8-byte reads of the
IPv6 words (upstream supports them through machinery this verifier lacks), so
programs that do that are rejected. `GETPEERNAME/GETSOCKNAME/POST_BIND` attach
types and `bpf_sock_addr.sk` do not exist in this tree.

Checked: the new `sock_addr_is_valid_access()` was compiled in userspace against
the real `struct bpf_sock_addr`/`enum bpf_attach_type` of this tree and every
(attach type, offset, size, direction) combination was enumerated. The kernel
itself was **not** compiled and nothing was tested on hardware.

Reminder: none of this lifts the userspace version gate described above. The
Android `NetBpfLoad` still stops on a 3.18 `uname` before loading anything.

### `BPF_MAP_LOOKUP_AND_DELETE_ELEM` (hash maps)

| Arquivo | Mudança |
|---|---|
| `include/uapi/linux/bpf.h` | `BPF_MAP_LOOKUP_AND_DELETE_ELEM = 21` (número do ABI upstream). 19 e 20 continuam não implementados. |
| `include/linux/bpf.h` | Novo `map_lookup_and_delete_elem` em `struct bpf_map_ops` (NULL = tipo não suporta). |
| `kernel/bpf/hashtab.c` | Implementado para `HASH`, `LRU_HASH`, `PERCPU_HASH` e `LRU_PERCPU_HASH`. O valor é copiado com o lock do bucket seguro e o elemento é desligado e liberado na mesma seção crítica; duas chamadas concorrentes nunca devolvem o mesmo elemento. Por CPU: mesmo layout de `BPF_MAP_LOOKUP_ELEM` (`round_up(value_size, 8)` por CPU possível). Nos mapas LRU o nó volta à lista livre depois de soltar o lock, como em `htab_lru_map_delete_elem()`. |
| `kernel/bpf/syscall.c` | `map_lookup_and_delete_elem()`: exige fd com leitura **e** escrita (`-EPERM`), mapa congelado devolve `-EPERM`, tipos sem suporte devolvem `-ENOTSUPP`, `flags != 0` devolve `-EINVAL` (não há `BPF_F_LOCK` aqui). Usa a mesma proteção `bpf_prog_active` do delete. |

Não implementado: pilha/fila (os tipos não existem neste kernel), `lpm_trie`, `BPF_F_LOCK`.
Impacto no boot do Android 17: não demonstrado; é paridade de UAPI com o Linux 6.6.
Verificado só por leitura e compilação sintática em userspace do trecho novo do `hashtab.c`
com stubs. Não compilado como parte do kernel, não testado em aparelho.
