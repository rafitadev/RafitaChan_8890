# SukiSU Ultra no Exynos8890 (Kernel Android 3.x) — Integração Manual

> Objetivo: integrar SukiSU Ultra em árvore 3.x com SUSFS manual, hooks manuais e ajustes de BPF/configuração, sem scripts automáticos de boot.

## 0) Pré-requisitos e segurança

```bash
cd /workspace/RafitaChan_8890
git checkout -b feat/sukisu-ultra-3x-manual
git status
```

- `cd ...`: entra na árvore do kernel.
- `git checkout -b ...`: cria branch isolada para rollback fácil.
- `git status`: valida que a árvore está limpa antes de aplicar patch.

**Precauções anti-bootloop**
- Sempre salve `defconfig` e `boot.img` originais antes de testar.
- Faça teste incremental: compile após cada bloco (SUSFS, hooks, BPF, config).
- Se faltar símbolo no link final (`undefined reference`), reverta o último bloco e reaplique com ajuste.

---

## 1) Baixar patches oficiais SukiSU Ultra

```bash
mkdir -p /tmp/sukisu_ultra_3x && cd /tmp/sukisu_ultra_3x
git clone --depth=1 https://github.com/SukiSU-Ultra/SukiSU_patch
git clone --depth=1 https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch
```

- Cria workspace temporário e baixa os dois repositórios oficiais.

---

## 2) Importar patchset em ordem correta (3.x: aplicação manual assistida)

> Para 3.x, não confiar em automação de 4.x. Aplique patch a patch com 3-way e resolva rejeições manualmente.

```bash
cd /workspace/RafitaChan_8890
START_COMMIT=$(git rev-parse HEAD)

find /tmp/sukisu_ultra_3x/SukiSU_patch -type f \( -name '*.patch' -o -name '*.diff' \) | sort -V > /tmp/sukisu_base.list
find /tmp/sukisu_ultra_3x/SukiSU_KernelPatch_patch -type f \( -name '*.patch' -o -name '*.diff' \) | sort -V > /tmp/sukisu_kp.list
```

- `START_COMMIT`: marca base para gerar diff final.
- `find ... | sort -V`: força ordem estável de aplicação (base antes de KernelPatch).

### Aplicação da base

```bash
while IFS= read -r p; do
  echo "[BASE] $p"
  git am --3way --keep-cr "$p" || {
    git am --abort || true
    git apply --3way --index "$p" || {
      echo "Falha em $p (resolver .rej/manual e continuar)."
      exit 1
    }
    git commit -m "SukiSU Ultra 3.x manual: $(basename "$p")"
  }
done < /tmp/sukisu_base.list
```

### Aplicação do KernelPatch

```bash
while IFS= read -r p; do
  echo "[KP] $p"
  git am --3way --keep-cr "$p" || {
    git am --abort || true
    git apply --3way --index "$p" || {
      echo "Falha em $p (resolver .rej/manual e continuar)."
      exit 1
    }
    git commit -m "SukiSU KernelPatch 3.x manual: $(basename "$p")"
  }
done < /tmp/sukisu_kp.list
```

- Estratégia em duas camadas reduz falhas por diferença de contexto do kernel 3.x.

---

## 3) SUSFS no kernel 3.x (manual mount + integração)

> Em kernel 3.x, normalmente é necessário portar partes do SUSFS e registrar pontos manualmente quando APIs divergem.

### 3.1 Copiar fontes SUSFS e integrar no Kbuild

```bash
# Exemplo de destino (ajuste caso o patch já tenha criado diretórios):
mkdir -p fs/susfs include/linux

# Copie arquivos SUSFS vindos dos patches/referência para a árvore (ajuste nomes reais):
# cp /tmp/sukisu_ultra_3x/.../susfs/* fs/susfs/
# cp /tmp/sukisu_ultra_3x/.../susfs/include/* include/linux/

# Garantir build no fs/Makefile
grep -q 'susfs/' fs/Makefile || echo 'obj-$(CONFIG_KSU_SUSFS) += susfs/' >> fs/Makefile

# Garantir Kconfig
grep -q 'source "fs/susfs/Kconfig"' fs/Kconfig || echo 'source "fs/susfs/Kconfig"' >> fs/Kconfig
```

- Inclui SUSFS no grafo de build e menuconfig.

### 3.2 Hook de mount manual (3.x)

```bash
# Localizar pontos do caminho de mount em kernels 3.x:
rg -n "do_mount|sys_mount|path_mount|vfs_kern_mount" fs/ kernel/
```

Aplicar hook manual no ponto existente do seu 3.x (normalmente `do_mount()` ou wrapper de syscall):

```c
/* Exemplo conceitual: inserir no fluxo antes de executar mount real */
#ifdef CONFIG_KSU_SUSFS
	if (susfs_handle_mount(dev_name, dir_name, type_page, flags, data_page))
		return 0;
#endif
```

- Se o protótipo divergir no 3.x, adapte os argumentos mantendo semântica.
- Não introduzir hook após alterações destrutivas de ponteiros de userspace.

### 3.3 Hook de lookup/path (quando exigido pelo patchset)

```bash
rg -n "vfs_stat|vfs_lstat|do_filp_open|filename_lookup|user_path_at" fs/ kernel/
```

Inserir blocos `#ifdef CONFIG_KSU_SUSFS` nos mesmos pontos lógicos pedidos pelo patch (ocultação/redirecionamento), sempre preservando retorno de erro original do kernel em caso de falha SUSFS.

---

## 4) Hooks manuais SukiSU Ultra (garantir todos os pontos)

> Checklist para 3.x: localizar e ligar manualmente os hooks quando patch não encaixar limpo.

```bash
# Segurança / credenciais
rg -n "commit_creds|prepare_kernel_cred|security_" kernel/ security/

# Exec/argv/env
rg -n "do_execve|search_binary_handler|bprm_" fs/ kernel/

# Arquivos / proc
rg -n "proc_create|proc_ops|file_operations|iterate_shared" fs/ kernel/

# Namespace / mount / path
rg -n "mnt|mount|namespace|path_lookupat|user_path" fs/ kernel/
```

### Regra de ouro dos hooks (3.x)
- Hook **antes** do comportamento final da função alvo.
- Retorno de hook deve respeitar convenção local (`0`, `-EPERM`, `-ENOENT`, etc.).
- Código de hook encapsulado em `#ifdef CONFIG_KSU` / `#ifdef CONFIG_KSU_SUSFS`.
- Nunca remover caminho original; apenas envolver/encadear.

---

## 5) BPF mínimo necessário no kernel 3.x

> Em 3.x, eBPF completo pode não existir. Habilite o mínimo suportado pela sua base.

### 5.1 Encontrar opções suportadas

```bash
rg -n "config BPF|config BPF_SYSCALL|config HAVE_EBPF_JIT|config BPF_JIT" kernel/ net/ lib/ init/ arch/
```

### 5.2 Ajustes de Kconfig/.config (somente símbolos existentes)

```bash
CFG=.config

# Símbolos mandatórios SukiSU Ultra
scripts/config --file "$CFG" -e CONFIG_KSU -e CONFIG_KSU_SUSFS -e CONFIG_KPM -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL || true

# BPF em 3.x (habilitar apenas se existir)
for s in CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_HAVE_EBPF_JIT; do
  if rg -n "^config ${s#CONFIG_}\b" -g 'Kconfig*' >/dev/null; then
    scripts/config --file "$CFG" -e "$s" || true
  fi
done
```

Fallback sem `scripts/config`:

```bash
for s in CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_KPM CONFIG_KALLSYMS CONFIG_KALLSYMS_ALL; do
  sed -i -E "s/^# ${s} is not set$/${s}=y/; t; s/^${s}=.*/${s}=y/; t; \$a${s}=y" .config
done
```

### 5.3 Normalizar config

```bash
make olddefconfig
```

- Recalcula dependências e evita quebra por símbolo inconsistente.

---

## 6) Validação de hooks/SUSFS antes de compilar

```bash
# Confirmar símbolos obrigatórios na config
rg -n "^(CONFIG_KSU|CONFIG_KSU_SUSFS|CONFIG_KPM|CONFIG_KALLSYMS|CONFIG_KALLSYMS_ALL)=y$" .config

# Confirmar referência SUSFS no build
rg -n "susfs|CONFIG_KSU_SUSFS" fs/ include/ kernel/

# Confirmar pontos de hook inseridos
rg -n "CONFIG_KSU|CONFIG_KSU_SUSFS|susfs_handle_mount|ksu_" fs/ kernel/ security/
```

---

## 7) Build e geração de patch final aplicável

```bash
# Compile com sua toolchain padrão do device
make -j"$(nproc)" 2>&1 | tee /tmp/sukisu_ultra_3x_build.log

# Gerar diff único aplicável
git diff "$START_COMMIT"..HEAD > sukisu_ultra_integration_3x.diff

# Opcional: série de commits
git format-patch "$START_COMMIT" -o /tmp/sukisu_ultra_3x_format_patch
```

- `sukisu_ultra_integration_3x.diff` é o patch consolidado para aplicar em árvore idêntica.
- `format-patch` preserva histórico por etapa (melhor para revisão).

---

## 8) Comandos de rollback rápido

```bash
# Desfazer mudanças não commitadas
git reset --hard

# Voltar exatamente ao ponto inicial
git reset --hard "$START_COMMIT"

# Limpar artefatos
git clean -fd
```

---

## 9) Ordem recomendada de integração (obrigatória para 3.x)

1. Aplicar `SukiSU_patch` (base).
2. Aplicar `SukiSU_KernelPatch_patch`.
3. Portar/ajustar SUSFS manualmente nos pontos de mount/path do 3.x.
4. Inserir hooks manuais faltantes (cred/exec/proc/mount).
5. Ativar configs mandatórias + BPF suportado.
6. `make olddefconfig`.
7. Build.
8. Gerar diff final.

