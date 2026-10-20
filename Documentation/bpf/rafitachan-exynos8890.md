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

## 4. O que NÃO está implementado (limitações honestas)

- **BTF real**: o tipo de cada entrada não é interpretado. O shim existe só
  para o `NetBpfLoad` não abortar. Programas que dependem de verificação por BTF
  (funções globais, `func_info`) podem falhar no verificador.
- **DEVMAP_HASH real**: sem `bpf_redirect_map` nele; é só um hash u32→u32.
- **Verificador**: faltam chamadas bpf-to-bpf (`BPF_PSEUDO_CALL`), a mitigação de
  Spectre v4 (`sanitize_ptr_alu`) e rastreamento de limites de 32 bits (`tnum`/
  `subreg`). O JMP32 existe, mas sem refinamento de limites: um programa que
  dependa de um `if (w1 < N)` para provar um acesso válido será rejeitado.
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
3. `sanitize_ptr_alu` e `BPF_JMP32` no verificador, só com testes em dispositivo.
4. Parser BTF real, se algum programa exigir verificação por tipos.
