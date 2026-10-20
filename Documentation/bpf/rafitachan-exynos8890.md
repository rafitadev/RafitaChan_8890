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
- JIT ARM64 com blinding de constantes, imagem somente-leitura, offset aleatório
  e `bpf_jit_limit`. Classic BPF e seccomp-BPF preservados.

## 3. Alterações desta branch (`rafitachan-bpf-hardening`)

| Arquivo | Mudança |
|---|---|
| `kernel/bpf/syscall.c` | `BPF_BTF_LOAD` exige `CAP_SYS_ADMIN` (como o upstream 4.19) e valida o cabeçalho do blob BTF (magic, versão, flags, limites, ordem e alinhamento das seções, seção de strings terminada em NUL). Antes aceitava qualquer blob de até 16 MB sem privilégio. |
| `kernel/bpf/hashtab.c` | `BPF_MAP_TYPE_DEVMAP_HASH` deixou de ser um hash genérico com outro nome: agora exige chave `u32` e valor `u32`, como no upstream. |
| `include/uapi/linux/bpf.h` | Comentário de `BPF_PROG_TEST_RUN` corrigido: o comando **não** está implementado (retorna `-EINVAL`). |

## 4. O que NÃO está implementado (limitações honestas)

- **BTF real**: o tipo de cada entrada não é interpretado. O shim existe só
  para o `NetBpfLoad` não abortar. Programas que dependem de verificação por BTF
  (funções globais, `func_info`) podem falhar no verificador.
- **DEVMAP_HASH real**: sem `bpf_redirect_map` nele; é só um hash u32→u32.
- **Verificador**: faltam `BPF_JMP32`, chamadas bpf-to-bpf (`BPF_PSEUDO_CALL`) e
  a mitigação de Spectre v4 (`sanitize_ptr_alu`). Programas compilados para
  clang `-mcpu=v3` ou que usem subprogramas serão rejeitados.
- **JIT ARM64**: sem tail call; programas com tail call caem no interpretador
  (`bpf_check_tail_call` cuida da consistência).
- Sem `BPF_MAP_TYPE_RINGBUF`, `BPF_F_MMAPABLE`, `clsact`, `BPF_PROG_TEST_RUN`.
  O loader do Android pula programas cujo `min_kver` é maior que o do kernel.
- **Requisito do Android**: o `NetBpfLoad` do Android V (15) em diante aborta
  se o kernel for menor que 4.19. Com `uname` real de 3.18 isso depende de
  ajuste no userspace (fora deste repositório).

## 5. Próximos passos sugeridos

1. Compilar e capturar o log do `NetBpfLoad`/`netd` para ver a próxima falha real.
2. Tail call no JIT ARM64 (a partir do upstream, com revisão cuidadosa).
3. `sanitize_ptr_alu` e `BPF_JMP32` no verificador, só com testes em dispositivo.
4. Parser BTF real, se algum programa exigir verificação por tipos.
