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
