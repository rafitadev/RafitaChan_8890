// SPDX-License-Identifier: GPL-2.0
/* Copyright (c) 2018 Facebook
 *
 * BTF (BPF Type Format) loader and validator.
 *
 * RafitaChan backport (Linux 3.18.140 base). The on-disk format, the
 * per-kind rules and the validation order follow Linux 6.6
 * (kernel/bpf/btf.c). What is deliberately different from upstream:
 *
 *  - no IDR / BTF_GET_FD_BY_ID, no vmlinux/module BTF, no CO-RE relocation
 *    support and no kfunc/struct_ops/kptr support (none of these exist in
 *    this kernel);
 *  - size resolution uses a recursive walk bounded by
 *    BTF_MAX_RESOLVE_DEPTH with a memoised size table instead of upstream's
 *    explicit resolve stack; the accepted language is the same;
 *  - the verifier log only records errors (no per-type listing);
 *  - the parsed BTF is validated and kept alive by its fd, but the BPF
 *    verifier does not consume it (no BTF-typed pointers, no global
 *    functions); see Documentation/bpf/rafitachan-exynos8890.md.
 */
#include <linux/kernel.h>
#include <linux/types.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/string.h>
#include <linux/ctype.h>
#include <linux/err.h>
#include <linux/log2.h>
#include <linux/kallsyms.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/anon_inodes.h>
#include <linux/uaccess.h>
#include <linux/capability.h>
#include <linux/atomic.h>
#include <linux/bpf.h>
#include <linux/btf.h>

/* Marker for "this type has no size" (void, fwd, func, func_proto, ...) */
#define BTF_SZ_NONE		U32_MAX
#define BTF_MAX_RESOLVE_DEPTH	32
#define BTF_LOG_MAX		(1U << 20)

enum {
	BTF_UNSEEN = 0,
	BTF_BUSY,
	BTF_DONE,
};

struct btf {
	void *data;			/* kernel copy of the blob */
	u32 data_size;
	struct btf_header hdr;
	const char *strings;
	const u8 *types;
	u32 *type_off;			/* [id] -> byte offset in 'types' */
	u32 *rsize;			/* [id] -> resolved size or BTF_SZ_NONE */
	u32 nr_types;			/* number of types, excluding void (0) */
	u32 id;
	atomic_t refcnt;
};

struct btf_log {
	u32 level;
	char *kbuf;
	u32 size;
	u32 len;
};

struct btf_env {
	struct btf *btf;
	struct btf_log log;
	u8 *state;
	u32 max_types;
	u32 cur_id;
};

static const struct btf_type btf_void = { .name_off = 0, .info = 0, .size = 0 };
static atomic_t btf_id_gen = ATOMIC_INIT(0);

static void __attribute__((format(printf, 2, 3)))
btf_log(struct btf_env *env, const char *fmt, ...)
{
	struct btf_log *log = &env->log;
	va_list args;
	int n;

	if (!log->level || !log->kbuf || log->len + 1 >= log->size)
		return;

	va_start(args, fmt);
	n = vsnprintf(log->kbuf + log->len, log->size - log->len, fmt, args);
	va_end(args);
	if (n < 0)
		return;
	if ((u32)n >= log->size - log->len)
		log->len = log->size - 1;	/* truncated */
	else
		log->len += n;
}

#define BTF_FAIL(env, fmt, ...) do {					\
	btf_log((env), "[%u] " fmt "\n", (env)->cur_id, ##__VA_ARGS__);	\
	return -EINVAL;							\
} while (0)

#define BTF_HFAIL(env, fmt, ...) do {					\
	btf_log((env), fmt "\n", ##__VA_ARGS__);			\
	return -EINVAL;							\
} while (0)

/* ---------------------------------------------------------------------- */
/* Small helpers                                                          */
/* ---------------------------------------------------------------------- */

static inline u32 btf_kind(const struct btf_type *t)
{
	return BTF_INFO_KIND(t->info);
}

static inline u32 btf_vlen(const struct btf_type *t)
{
	return BTF_INFO_VLEN(t->info);
}

static bool btf_kind_is_modifier(u32 k)
{
	return k == BTF_KIND_TYPEDEF || k == BTF_KIND_VOLATILE ||
	       k == BTF_KIND_CONST || k == BTF_KIND_RESTRICT ||
	       k == BTF_KIND_TYPE_TAG;
}

/* kinds that can never be the target of a ptr/modifier/member/param */
static bool btf_kind_is_no_target(u32 k)
{
	return k == BTF_KIND_VAR || k == BTF_KIND_DATASEC ||
	       k == BTF_KIND_FUNC || k == BTF_KIND_DECL_TAG;
}

const struct btf_type *btf_type_by_id(const struct btf *btf, u32 id)
{
	if (!id)
		return &btf_void;
	if (id > btf->nr_types)
		return NULL;
	return (const struct btf_type *)(btf->types + btf->type_off[id]);
}

static bool btf_name_offset_valid(const struct btf *btf, u32 offset)
{
	return offset < btf->hdr.str_len;
}

const char *btf_name_by_offset(const struct btf *btf, u32 offset)
{
	if (!offset)
		return "(anon)";
	if (offset < btf->hdr.str_len)
		return btf->strings + offset;
	return "(invalid-name-offset)";
}

static bool btf_name_char_ok(char c, bool first)
{
	if ((first ? !isalpha(c) : !isalnum(c)) && c != '_' && c != '.')
		return false;
	return true;
}

/* [A-Za-z_.][A-Za-z0-9_.]*, shorter than KSYM_NAME_LEN */
static bool btf_name_valid_identifier(const struct btf *btf, u32 offset)
{
	const char *src = btf->strings + offset;
	const char *limit = src + KSYM_NAME_LEN;

	if (!btf_name_char_ok(*src, true))
		return false;
	src++;
	while (*src && src < limit) {
		if (!btf_name_char_ok(*src, false))
			return false;
		src++;
	}
	return !*src;
}

static bool btf_name_valid_section(const struct btf *btf, u32 offset)
{
	const char *src = btf->strings + offset;
	const char *limit = src + KSYM_NAME_LEN;

	if (!btf_name_char_ok(*src, true))
		return false;
	src++;
	while (*src && src < limit) {
		if (!isprint(*src))
			return false;
		src++;
	}
	return !*src;
}

/* ---------------------------------------------------------------------- */
/* Header and sections                                                    */
/* ---------------------------------------------------------------------- */

static int btf_check_hdr(struct btf_env *env, u32 size)
{
	struct btf *btf = env->btf;
	const struct btf_header *h = btf->data;
	struct { u32 off, len; } s[2], tmp;
	u32 hdr_len, meta_left;

	if (size < sizeof(*h))
		BTF_HFAIL(env, "btf_header is incomplete");
	hdr_len = h->hdr_len;
	if (hdr_len < sizeof(*h) || hdr_len > size || (hdr_len & 3))
		BTF_HFAIL(env, "Invalid hdr_len %u", hdr_len);
	/* unknown (newer) header bytes must be zero */
	if (hdr_len > sizeof(*h) &&
	    memchr_inv((const u8 *)btf->data + sizeof(*h), 0,
		       hdr_len - sizeof(*h)))
		BTF_HFAIL(env, "Unsupported btf_header");
	if (h->flags)
		BTF_HFAIL(env, "Unsupported flags %#x", h->flags);
	if (h->magic != BTF_MAGIC)
		BTF_HFAIL(env, "Invalid magic");
	if (h->version != BTF_VERSION)
		BTF_HFAIL(env, "Unsupported version %u", h->version);

	meta_left = size - hdr_len;
	if (!meta_left)
		BTF_HFAIL(env, "No data");

	/* The type and string sections must tile the data exactly. */
	s[0].off = h->type_off; s[0].len = h->type_len;
	s[1].off = h->str_off;  s[1].len = h->str_len;
	if (s[1].off < s[0].off) {
		tmp = s[0]; s[0] = s[1]; s[1] = tmp;
	}
	if (s[0].off != 0 ||
	    (u64)s[0].off + s[0].len != s[1].off ||
	    (u64)s[1].off + s[1].len != meta_left)
		BTF_HFAIL(env, "Invalid section layout");
	if (h->type_off & 3)
		BTF_HFAIL(env, "Misaligned type section");
	if (!h->str_len || h->str_len - 1 > BTF_MAX_NAME_OFFSET)
		BTF_HFAIL(env, "Invalid string section length %u", h->str_len);

	btf->hdr = *h;
	btf->types = (const u8 *)btf->data + hdr_len + h->type_off;
	btf->strings = (const char *)btf->data + hdr_len + h->str_off;

	if (btf->strings[0] || btf->strings[h->str_len - 1])
		BTF_HFAIL(env, "Invalid string section");
	return 0;
}

/* ---------------------------------------------------------------------- */
/* Pass 1: per-kind metadata checks. Each returns the number of extra      */
/* bytes that follow struct btf_type, or -EINVAL.                          */
/* ---------------------------------------------------------------------- */

typedef int (*btf_meta_fn)(struct btf_env *env, const struct btf_type *t,
			   u32 meta_left);

static int btf_chk_int(struct btf_env *env, const struct btf_type *t,
		       u32 meta_left)
{
	u32 int_data, nr_bits, enc;

	if (meta_left < sizeof(u32))
		BTF_FAIL(env, "Incomplete INT");
	if (btf_vlen(t))
		BTF_FAIL(env, "INT vlen != 0");
	if (BTF_INFO_KFLAG(t->info))
		BTF_FAIL(env, "INT kind_flag != 0");

	int_data = *(const u32 *)(t + 1);
	if (int_data & 0xf0000000)
		BTF_FAIL(env, "Invalid int_data %#x", int_data);
	nr_bits = BTF_INT_BITS(int_data);
	if (nr_bits > 128)
		BTF_FAIL(env, "nr_bits exceeds 128");
	if ((nr_bits + 7) / 8 > t->size)
		BTF_FAIL(env, "nr_bits exceeds type_size");
	if ((u64)BTF_INT_OFFSET(int_data) + nr_bits > 8ULL * t->size)
		BTF_FAIL(env, "Invalid offset/bits");
	enc = BTF_INT_ENCODING(int_data);
	if (enc && enc != BTF_INT_SIGNED && enc != BTF_INT_CHAR &&
	    enc != BTF_INT_BOOL)
		BTF_FAIL(env, "Unsupported encoding %#x", enc);
	return sizeof(u32);
}

/* PTR, TYPEDEF, VOLATILE, CONST, RESTRICT, TYPE_TAG */
static int btf_chk_ref(struct btf_env *env, const struct btf_type *t,
		       u32 meta_left)
{
	u32 k = btf_kind(t);

	if (btf_vlen(t))
		BTF_FAIL(env, "vlen != 0");
	if (BTF_INFO_KFLAG(t->info))
		BTF_FAIL(env, "kind_flag != 0");
	if (t->type > BTF_MAX_TYPE)
		BTF_FAIL(env, "Invalid type_id");
	if (k == BTF_KIND_TYPEDEF || k == BTF_KIND_TYPE_TAG) {
		if (!btf_name_valid_identifier(env->btf, t->name_off))
			BTF_FAIL(env, "Invalid name");
	} else if (t->name_off) {
		BTF_FAIL(env, "Invalid name");
	}
	return 0;
}

static int btf_chk_array(struct btf_env *env, const struct btf_type *t,
			 u32 meta_left)
{
	const struct btf_array *a = (const struct btf_array *)(t + 1);

	if (meta_left < sizeof(*a))
		BTF_FAIL(env, "Incomplete ARRAY");
	if (t->name_off)
		BTF_FAIL(env, "Invalid name");
	if (btf_vlen(t))
		BTF_FAIL(env, "vlen != 0");
	if (BTF_INFO_KFLAG(t->info))
		BTF_FAIL(env, "kind_flag != 0");
	if (t->size)
		BTF_FAIL(env, "size != 0");
	if (!a->type || a->type > BTF_MAX_TYPE)
		BTF_FAIL(env, "Invalid elem");
	if (!a->index_type || a->index_type > BTF_MAX_TYPE)
		BTF_FAIL(env, "Invalid index");
	return sizeof(*a);
}

static int btf_chk_struct(struct btf_env *env, const struct btf_type *t,
			  u32 meta_left)
{
	const struct btf_member *m = (const struct btf_member *)(t + 1);
	bool is_union = btf_kind(t) == BTF_KIND_UNION;
	bool kflag = BTF_INFO_KFLAG(t->info);
	u32 vlen = btf_vlen(t), i, last_off = 0;
	u32 meta_needed = vlen * sizeof(*m);

	if (meta_left < meta_needed)
		BTF_FAIL(env, "meta_left:%u < meta_needed:%u", meta_left,
			 meta_needed);
	if (t->name_off && !btf_name_valid_identifier(env->btf, t->name_off))
		BTF_FAIL(env, "Invalid name");

	for (i = 0; i < vlen; i++, m++) {
		u32 off = kflag ? BTF_MEMBER_BIT_OFFSET(m->offset) : m->offset;

		if (!btf_name_offset_valid(env->btf, m->name_off))
			BTF_FAIL(env, "Invalid member #%u name_offset", i);
		if (m->name_off &&
		    !btf_name_valid_identifier(env->btf, m->name_off))
			BTF_FAIL(env, "Invalid member #%u name", i);
		/* A member cannot be of type void */
		if (!m->type || m->type > BTF_MAX_TYPE)
			BTF_FAIL(env, "Invalid member #%u type_id", i);
		if (is_union && off)
			BTF_FAIL(env, "Invalid union member #%u bits_offset", i);
		if (last_off > off)
			BTF_FAIL(env, "Invalid member #%u bits_offset", i);
		if (((u64)off + 7) / 8 > t->size)
			BTF_FAIL(env, "Member #%u bits_offset exceeds struct size", i);
		last_off = off;
	}
	return meta_needed;
}

static int btf_chk_enum(struct btf_env *env, const struct btf_type *t,
			u32 meta_left)
{
	const struct btf_enum *e = (const struct btf_enum *)(t + 1);
	u32 vlen = btf_vlen(t), i;
	u32 meta_needed = vlen * sizeof(*e);

	if (meta_left < meta_needed)
		BTF_FAIL(env, "meta_left:%u < meta_needed:%u", meta_left,
			 meta_needed);
	if (t->name_off && !btf_name_valid_identifier(env->btf, t->name_off))
		BTF_FAIL(env, "Invalid name");
	if (t->size == 0 || t->size > 8 || !is_power_of_2(t->size))
		BTF_FAIL(env, "Unexpected size %u", t->size);
	for (i = 0; i < vlen; i++, e++) {
		if (!btf_name_offset_valid(env->btf, e->name_off) ||
		    !btf_name_valid_identifier(env->btf, e->name_off))
			BTF_FAIL(env, "Invalid enum #%u name", i);
	}
	return meta_needed;
}

static int btf_chk_enum64(struct btf_env *env, const struct btf_type *t,
			  u32 meta_left)
{
	const struct btf_enum64 *e = (const struct btf_enum64 *)(t + 1);
	u32 vlen = btf_vlen(t), i;
	u32 meta_needed = vlen * sizeof(*e);

	if (meta_left < meta_needed)
		BTF_FAIL(env, "meta_left:%u < meta_needed:%u", meta_left,
			 meta_needed);
	if (t->name_off && !btf_name_valid_identifier(env->btf, t->name_off))
		BTF_FAIL(env, "Invalid name");
	if (t->size == 0 || t->size > 8 || !is_power_of_2(t->size))
		BTF_FAIL(env, "Unexpected size %u", t->size);
	for (i = 0; i < vlen; i++, e++) {
		if (!btf_name_offset_valid(env->btf, e->name_off) ||
		    !btf_name_valid_identifier(env->btf, e->name_off))
			BTF_FAIL(env, "Invalid enum #%u name", i);
	}
	return meta_needed;
}

static int btf_chk_fwd(struct btf_env *env, const struct btf_type *t,
		       u32 meta_left)
{
	if (btf_vlen(t))
		BTF_FAIL(env, "vlen != 0");
	if (t->type)
		BTF_FAIL(env, "type != 0");
	if (!btf_name_valid_identifier(env->btf, t->name_off))
		BTF_FAIL(env, "Invalid name");
	return 0;
}

static int btf_chk_func(struct btf_env *env, const struct btf_type *t,
			u32 meta_left)
{
	u32 linkage = btf_vlen(t);

	if (BTF_INFO_KFLAG(t->info))
		BTF_FAIL(env, "kind_flag != 0");
	if (linkage != BTF_FUNC_STATIC && linkage != BTF_FUNC_GLOBAL &&
	    linkage != BTF_FUNC_EXTERN)
		BTF_FAIL(env, "Invalid func linkage %u", linkage);
	if (!t->type || t->type > BTF_MAX_TYPE)
		BTF_FAIL(env, "Invalid type_id");
	if (!btf_name_valid_identifier(env->btf, t->name_off))
		BTF_FAIL(env, "Invalid name");
	return 0;
}

static int btf_chk_func_proto(struct btf_env *env, const struct btf_type *t,
			      u32 meta_left)
{
	const struct btf_param *p = (const struct btf_param *)(t + 1);
	u32 vlen = btf_vlen(t), i;
	u32 meta_needed = vlen * sizeof(*p);

	if (BTF_INFO_KFLAG(t->info))
		BTF_FAIL(env, "kind_flag != 0");
	if (t->name_off)
		BTF_FAIL(env, "Invalid name");
	if (t->type > BTF_MAX_TYPE)
		BTF_FAIL(env, "Invalid return type_id");
	if (meta_left < meta_needed)
		BTF_FAIL(env, "meta_left:%u < meta_needed:%u", meta_left,
			 meta_needed);
	for (i = 0; i < vlen; i++, p++) {
		if (!btf_name_offset_valid(env->btf, p->name_off))
			BTF_FAIL(env, "Invalid param #%u name_offset", i);
		if (p->name_off &&
		    !btf_name_valid_identifier(env->btf, p->name_off))
			BTF_FAIL(env, "Invalid param #%u name", i);
		if (p->type > BTF_MAX_TYPE)
			BTF_FAIL(env, "Invalid param #%u type_id", i);
	}
	return meta_needed;
}

static int btf_chk_var(struct btf_env *env, const struct btf_type *t,
		       u32 meta_left)
{
	const struct btf_var *v = (const struct btf_var *)(t + 1);

	if (meta_left < sizeof(*v))
		BTF_FAIL(env, "Incomplete VAR");
	if (btf_vlen(t))
		BTF_FAIL(env, "vlen != 0");
	if (BTF_INFO_KFLAG(t->info))
		BTF_FAIL(env, "kind_flag != 0");
	if (!t->type || t->type > BTF_MAX_TYPE)
		BTF_FAIL(env, "Invalid type_id");
	if (!btf_name_valid_identifier(env->btf, t->name_off))
		BTF_FAIL(env, "Invalid name");
	if (v->linkage != BTF_VAR_STATIC &&
	    v->linkage != BTF_VAR_GLOBAL_ALLOCATED &&
	    v->linkage != BTF_VAR_GLOBAL_EXTERN)
		BTF_FAIL(env, "Invalid linkage %u", v->linkage);
	return sizeof(*v);
}

static int btf_chk_datasec(struct btf_env *env, const struct btf_type *t,
			   u32 meta_left)
{
	const struct btf_var_secinfo *vsi =
		(const struct btf_var_secinfo *)(t + 1);
	u32 vlen = btf_vlen(t), i, last_end = 0;
	u32 meta_needed = vlen * sizeof(*vsi);

	if (BTF_INFO_KFLAG(t->info))
		BTF_FAIL(env, "kind_flag != 0");
	if (!vlen)
		BTF_FAIL(env, "vlen == 0");
	if (!t->size)
		BTF_FAIL(env, "size == 0");
	if (meta_left < meta_needed)
		BTF_FAIL(env, "meta_left:%u < meta_needed:%u", meta_left,
			 meta_needed);
	if (!btf_name_valid_section(env->btf, t->name_off))
		BTF_FAIL(env, "Invalid name");
	for (i = 0; i < vlen; i++, vsi++) {
		u64 end;

		if (!vsi->type || vsi->type > BTF_MAX_TYPE)
			BTF_FAIL(env, "Invalid secinfo #%u type_id", i);
		if (vsi->offset < last_end || vsi->offset >= t->size)
			BTF_FAIL(env, "Invalid secinfo #%u offset", i);
		if (!vsi->size || vsi->size > t->size)
			BTF_FAIL(env, "Invalid secinfo #%u size", i);
		end = (u64)vsi->offset + vsi->size;
		if (end > t->size)
			BTF_FAIL(env, "Secinfo #%u exceeds section size", i);
		last_end = end;
	}
	return meta_needed;
}

static int btf_chk_float(struct btf_env *env, const struct btf_type *t,
			 u32 meta_left)
{
	if (btf_vlen(t))
		BTF_FAIL(env, "vlen != 0");
	if (BTF_INFO_KFLAG(t->info))
		BTF_FAIL(env, "kind_flag != 0");
	if (t->size != 2 && t->size != 4 && t->size != 8 &&
	    t->size != 12 && t->size != 16)
		BTF_FAIL(env, "Invalid float size %u", t->size);
	return 0;
}

static int btf_chk_decl_tag(struct btf_env *env, const struct btf_type *t,
			    u32 meta_left)
{
	const struct btf_decl_tag *tag = (const struct btf_decl_tag *)(t + 1);

	if (meta_left < sizeof(*tag))
		BTF_FAIL(env, "Incomplete DECL_TAG");
	if (btf_vlen(t))
		BTF_FAIL(env, "vlen != 0");
	if (BTF_INFO_KFLAG(t->info))
		BTF_FAIL(env, "kind_flag != 0");
	if (!t->type || t->type > BTF_MAX_TYPE)
		BTF_FAIL(env, "Invalid type_id");
	if (!btf_name_offset_valid(env->btf, t->name_off) ||
	    !env->btf->strings[t->name_off])
		BTF_FAIL(env, "Invalid tag value");
	if (tag->component_idx < -1)
		BTF_FAIL(env, "Invalid component_idx");
	return sizeof(*tag);
}

static const btf_meta_fn btf_meta_ops[NR_BTF_KINDS] = {
	[BTF_KIND_INT]		= btf_chk_int,
	[BTF_KIND_PTR]		= btf_chk_ref,
	[BTF_KIND_ARRAY]	= btf_chk_array,
	[BTF_KIND_STRUCT]	= btf_chk_struct,
	[BTF_KIND_UNION]	= btf_chk_struct,
	[BTF_KIND_ENUM]		= btf_chk_enum,
	[BTF_KIND_FWD]		= btf_chk_fwd,
	[BTF_KIND_TYPEDEF]	= btf_chk_ref,
	[BTF_KIND_VOLATILE]	= btf_chk_ref,
	[BTF_KIND_CONST]	= btf_chk_ref,
	[BTF_KIND_RESTRICT]	= btf_chk_ref,
	[BTF_KIND_FUNC]		= btf_chk_func,
	[BTF_KIND_FUNC_PROTO]	= btf_chk_func_proto,
	[BTF_KIND_VAR]		= btf_chk_var,
	[BTF_KIND_DATASEC]	= btf_chk_datasec,
	[BTF_KIND_FLOAT]	= btf_chk_float,
	[BTF_KIND_DECL_TAG]	= btf_chk_decl_tag,
	[BTF_KIND_TYPE_TAG]	= btf_chk_ref,
	[BTF_KIND_ENUM64]	= btf_chk_enum64,
};

static int btf_check_all_metas(struct btf_env *env)
{
	struct btf *btf = env->btf;
	const u8 *cur = btf->types;
	const u8 *end = btf->types + btf->hdr.type_len;

	while (cur < end) {
		const struct btf_type *t = (const struct btf_type *)cur;
		u32 left = end - cur, kind;
		int ms;

		env->cur_id = btf->nr_types + 1;
		if (left < sizeof(*t))
			BTF_FAIL(env, "Incomplete type");
		if (btf->nr_types >= env->max_types)
			BTF_FAIL(env, "Too many types");
		if (t->info & ~BTF_INFO_MASK)
			BTF_FAIL(env, "Invalid btf_info %#x", t->info);
		kind = BTF_INFO_KIND(t->info);
		if (kind >= NR_BTF_KINDS || !btf_meta_ops[kind])
			BTF_FAIL(env, "Unsupported kind %u", kind);
		if (!btf_name_offset_valid(btf, t->name_off))
			BTF_FAIL(env, "Invalid name_offset %u", t->name_off);

		ms = btf_meta_ops[kind](env, t, left - sizeof(*t));
		if (ms < 0)
			return ms;

		btf->nr_types++;
		btf->type_off[btf->nr_types] = cur - btf->types;
		cur += sizeof(*t) + ms;
	}
	return 0;
}

/* ---------------------------------------------------------------------- */
/* Pass 2: resolve references, detect loops, compute sizes                */
/* ---------------------------------------------------------------------- */

static int btf_resolve(struct btf_env *env, u32 id, u32 depth);

/* Resolve @ref (void is allowed) and return its size (BTF_SZ_NONE if the
 * type has no size).
 */
static int btf_resolve_ref(struct btf_env *env, u32 ref, u32 depth, u32 *size)
{
	struct btf *btf = env->btf;
	u32 cur = env->cur_id;
	int err;

	if (ref > btf->nr_types)
		BTF_FAIL(env, "Invalid type_id %u", ref);
	if (!ref) {
		*size = BTF_SZ_NONE;
		return 0;
	}
	err = btf_resolve(env, ref, depth + 1);
	if (err)
		return err;
	env->cur_id = cur;
	*size = btf->rsize[ref];
	return 0;
}

/* Follow typedef/const/volatile/restrict/type_tag. Only called on types
 * that were already resolved, so the chain is known to be acyclic; the
 * iteration bound is defensive.
 */
static u32 btf_skip_mods(const struct btf *btf, u32 id)
{
	u32 n = btf->nr_types;

	while (n-- && id) {
		const struct btf_type *t = btf_type_by_id(btf, id);

		if (!t || !btf_kind_is_modifier(btf_kind(t)))
			break;
		id = t->type;
	}
	return id;
}

static int btf_resolve_member(struct btf_env *env, const struct btf_type *t,
			      const struct btf_member *m, u32 idx, u32 depth)
{
	struct btf *btf = env->btf;
	bool kflag = BTF_INFO_KFLAG(t->info);
	const struct btf_type *mt, *ft;
	u64 bit_off = kflag ? BTF_MEMBER_BIT_OFFSET(m->offset) : m->offset;
	u32 bfs = kflag ? BTF_MEMBER_BITFIELD_SIZE(m->offset) : 0;
	u32 msize, fin, fk;
	int err;

	err = btf_resolve_ref(env, m->type, depth, &msize);
	if (err)
		return err;
	mt = btf_type_by_id(btf, m->type);
	if (btf_kind_is_no_target(btf_kind(mt)) || msize == BTF_SZ_NONE)
		BTF_FAIL(env, "Invalid member #%u type", idx);

	fin = btf_skip_mods(btf, m->type);
	ft = btf_type_by_id(btf, fin);
	fk = btf_kind(ft);

	if (bfs) {
		if (fk != BTF_KIND_INT && fk != BTF_KIND_ENUM &&
		    fk != BTF_KIND_ENUM64)
			BTF_FAIL(env, "Member #%u: bitfield of non int/enum", idx);
		if (bfs > 8ULL * msize)
			BTF_FAIL(env, "Member #%u: bitfield size exceeds type", idx);
		if ((bit_off + bfs + 7) / 8 > t->size)
			BTF_FAIL(env, "Member #%u exceeds struct size", idx);
		return 0;
	}

	if (fk == BTF_KIND_INT && !kflag) {
		/* legacy bitfield encoding through BTF_INT_BITS/OFFSET */
		u32 int_data = *(const u32 *)(ft + 1);
		u32 nr_bits = BTF_INT_BITS(int_data);
		u32 bits_off = bit_off & 7;
		u64 bytes_off = bit_off / 8;

		if (bits_off && bits_off + nr_bits > 8ULL * msize)
			BTF_FAIL(env, "Member #%u exceeds its type", idx);
		/* bytes touched by the (possibly partial) integer */
		if (bytes_off + (((u64)bits_off + nr_bits + 7) / 8) > t->size)
			BTF_FAIL(env, "Member #%u exceeds struct size", idx);
		return 0;
	}

	if (bit_off & 7)
		BTF_FAIL(env, "Member #%u is not byte aligned", idx);
	if (bit_off / 8 + (u64)msize > t->size)
		BTF_FAIL(env, "Member #%u exceeds struct size", idx);
	return 0;
}

static int btf_resolve(struct btf_env *env, u32 id, u32 depth)
{
	struct btf *btf = env->btf;
	const struct btf_type *t = btf_type_by_id(btf, id);
	u32 k, i, size;
	int err;

	if (!id)
		return 0;
	if (env->state[id] == BTF_DONE)
		return 0;
	env->cur_id = id;
	if (env->state[id] == BTF_BUSY)
		BTF_FAIL(env, "Loop detected");
	if (depth > BTF_MAX_RESOLVE_DEPTH) {
		btf_log(env, "[%u] Exceeded max resolving depth\n", id);
		return -E2BIG;
	}
	env->state[id] = BTF_BUSY;
	k = btf_kind(t);

	switch (k) {
	case BTF_KIND_INT:
	case BTF_KIND_FLOAT:
	case BTF_KIND_ENUM:
	case BTF_KIND_ENUM64:
		btf->rsize[id] = t->size;
		break;

	case BTF_KIND_FWD:
		btf->rsize[id] = BTF_SZ_NONE;
		break;

	case BTF_KIND_PTR: {
		const struct btf_type *tt = btf_type_by_id(btf, t->type);

		if (!tt)
			BTF_FAIL(env, "Invalid type_id %u", t->type);
		if (btf_kind_is_no_target(btf_kind(tt)))
			BTF_FAIL(env, "Invalid ptr target kind");
		/* A pointer does not need its target resolved to know its
		 * size, which is what allows self-referential structs.
		 */
		btf->rsize[id] = sizeof(void *);
		break;
	}

	case BTF_KIND_TYPEDEF:
	case BTF_KIND_VOLATILE:
	case BTF_KIND_CONST:
	case BTF_KIND_RESTRICT:
	case BTF_KIND_TYPE_TAG: {
		const struct btf_type *tt = btf_type_by_id(btf, t->type);

		if (!tt)
			BTF_FAIL(env, "Invalid type_id %u", t->type);
		if (btf_kind_is_no_target(btf_kind(tt)))
			BTF_FAIL(env, "Invalid modifier target kind");
		err = btf_resolve_ref(env, t->type, depth, &size);
		if (err)
			return err;
		btf->rsize[id] = size;
		break;
	}

	case BTF_KIND_ARRAY: {
		const struct btf_array *a = (const struct btf_array *)(t + 1);
		const struct btf_type *it = btf_type_by_id(btf, a->index_type);
		const struct btf_type *et = btf_type_by_id(btf, a->type);
		u64 total;

		if (!it || !et)
			BTF_FAIL(env, "Invalid elem/index type_id");
		if (btf_kind(it) != BTF_KIND_INT)
			BTF_FAIL(env, "Invalid index type (not INT)");
		if (btf_kind_is_no_target(btf_kind(et)))
			BTF_FAIL(env, "Invalid elem type kind");
		err = btf_resolve_ref(env, a->type, depth, &size);
		if (err)
			return err;
		if (size == BTF_SZ_NONE)
			BTF_FAIL(env, "Invalid elem (no size)");
		total = (u64)size * a->nelems;
		if (total >= BTF_SZ_NONE)
			BTF_FAIL(env, "Array size overflow");
		btf->rsize[id] = total;
		break;
	}

	case BTF_KIND_STRUCT:
	case BTF_KIND_UNION: {
		const struct btf_member *m = (const struct btf_member *)(t + 1);

		for (i = 0; i < btf_vlen(t); i++, m++) {
			err = btf_resolve_member(env, t, m, i, depth);
			if (err)
				return err;
			env->cur_id = id;
		}
		btf->rsize[id] = t->size;
		break;
	}

	case BTF_KIND_FUNC: {
		const struct btf_type *proto = btf_type_by_id(btf, t->type);

		if (!proto || btf_kind(proto) != BTF_KIND_FUNC_PROTO)
			BTF_FAIL(env, "FUNC type_id is not a FUNC_PROTO");
		btf->rsize[id] = BTF_SZ_NONE;
		break;
	}

	case BTF_KIND_FUNC_PROTO: {
		const struct btf_param *p = (const struct btf_param *)(t + 1);
		u32 vlen = btf_vlen(t);

		if (t->type) {
			const struct btf_type *rt = btf_type_by_id(btf, t->type);

			if (!rt)
				BTF_FAIL(env, "Invalid return type_id");
			if (btf_kind_is_no_target(btf_kind(rt)))
				BTF_FAIL(env, "Invalid return type kind");
			err = btf_resolve_ref(env, t->type, depth, &size);
			if (err)
				return err;
			env->cur_id = id;
			if (size == BTF_SZ_NONE &&
			    btf_skip_mods(btf, t->type) != 0)
				BTF_FAIL(env, "Invalid return type (no size)");
		}
		for (i = 0; i < vlen; i++, p++) {
			const struct btf_type *pt;

			/* a trailing "..." is encoded as name_off=0,type=0 */
			if (i == vlen - 1 && !p->name_off && !p->type)
				continue;
			if (!p->type)
				BTF_FAIL(env, "Invalid param #%u type", i);
			pt = btf_type_by_id(btf, p->type);
			if (!pt)
				BTF_FAIL(env, "Invalid param #%u type_id", i);
			if (btf_kind_is_no_target(btf_kind(pt)))
				BTF_FAIL(env, "Invalid param #%u type kind", i);
			err = btf_resolve_ref(env, p->type, depth, &size);
			if (err)
				return err;
			env->cur_id = id;
			if (size == BTF_SZ_NONE)
				BTF_FAIL(env, "Invalid param #%u type (no size)", i);
		}
		btf->rsize[id] = BTF_SZ_NONE;
		break;
	}

	case BTF_KIND_VAR: {
		const struct btf_type *vt = btf_type_by_id(btf, t->type);

		if (!vt)
			BTF_FAIL(env, "Invalid type_id %u", t->type);
		if (btf_kind_is_no_target(btf_kind(vt)))
			BTF_FAIL(env, "Invalid var type kind");
		err = btf_resolve_ref(env, t->type, depth, &size);
		if (err)
			return err;
		env->cur_id = id;
		if (size == BTF_SZ_NONE)
			BTF_FAIL(env, "Invalid var type (no size)");
		btf->rsize[id] = size;	/* a VAR "has" the size of its type */
		break;
	}

	case BTF_KIND_DATASEC: {
		const struct btf_var_secinfo *vsi =
			(const struct btf_var_secinfo *)(t + 1);

		for (i = 0; i < btf_vlen(t); i++, vsi++) {
			const struct btf_type *vt = btf_type_by_id(btf, vsi->type);

			if (!vt || btf_kind(vt) != BTF_KIND_VAR)
				BTF_FAIL(env, "Secinfo #%u is not a VAR", i);
			err = btf_resolve(env, vsi->type, depth + 1);
			if (err)
				return err;
			env->cur_id = id;
			if (vsi->size < btf->rsize[vsi->type])
				BTF_FAIL(env, "Secinfo #%u size too small", i);
		}
		btf->rsize[id] = t->size;
		break;
	}

	case BTF_KIND_DECL_TAG: {
		const struct btf_decl_tag *tag =
			(const struct btf_decl_tag *)(t + 1);
		const struct btf_type *tt = btf_type_by_id(btf, t->type);
		u32 tk;

		if (!tt)
			BTF_FAIL(env, "Invalid type_id %u", t->type);
		tk = btf_kind(tt);
		if (tk != BTF_KIND_VAR && tk != BTF_KIND_TYPEDEF &&
		    tk != BTF_KIND_FUNC && tk != BTF_KIND_STRUCT &&
		    tk != BTF_KIND_UNION)
			BTF_FAIL(env, "Invalid decl_tag target kind");
		if (tk == BTF_KIND_VAR || tk == BTF_KIND_TYPEDEF) {
			if (tag->component_idx != -1)
				BTF_FAIL(env, "Invalid component_idx");
		} else if (tk == BTF_KIND_FUNC) {
			const struct btf_type *proto =
				btf_type_by_id(btf, tt->type);

			if (tag->component_idx != -1 &&
			    (!proto || btf_kind(proto) != BTF_KIND_FUNC_PROTO ||
			     (u32)tag->component_idx >= btf_vlen(proto)))
				BTF_FAIL(env, "Invalid component_idx");
		} else {
			if (tag->component_idx != -1 &&
			    (u32)tag->component_idx >= btf_vlen(tt))
				BTF_FAIL(env, "Invalid component_idx");
		}
		btf->rsize[id] = BTF_SZ_NONE;
		break;
	}

	default:
		BTF_FAIL(env, "Unsupported kind %u", k);
	}

	env->state[id] = BTF_DONE;
	return 0;
}

static int btf_resolve_all(struct btf_env *env)
{
	u32 id;
	int err;

	for (id = 1; id <= env->btf->nr_types; id++) {
		err = btf_resolve(env, id, 0);
		if (err)
			return err;
	}
	return 0;
}

/* ---------------------------------------------------------------------- */
/* Object management                                                      */
/* ---------------------------------------------------------------------- */

static void btf_free(struct btf *btf)
{
	if (!btf)
		return;
	vfree(btf->type_off);
	vfree(btf->rsize);
	vfree(btf->data);
	kfree(btf);
}

void btf_put(struct btf *btf)
{
	if (btf && atomic_dec_and_test(&btf->refcnt))
		btf_free(btf);
}

static int btf_release(struct inode *inode, struct file *filp)
{
	btf_put(filp->private_data);
	return 0;
}

static const struct file_operations btf_fops = {
	.release	= btf_release,
};

struct btf *btf_get_by_fd(int fd)
{
	struct btf *btf;
	struct fd f;

	f = fdget(fd);
	if (!f.file)
		return ERR_PTR(-EBADF);
	if (f.file->f_op != &btf_fops) {
		fdput(f);
		return ERR_PTR(-EINVAL);
	}
	btf = f.file->private_data;
	atomic_inc(&btf->refcnt);
	fdput(f);
	return btf;
}

static struct btf *btf_parse(struct btf_env *env, const void __user *ubtf,
			     u32 size)
{
	struct btf *btf;
	size_t n;
	int err = -ENOMEM;

	btf = kzalloc(sizeof(*btf), GFP_USER);
	if (!btf)
		return ERR_PTR(-ENOMEM);
	atomic_set(&btf->refcnt, 1);
	env->btf = btf;

	btf->data = vzalloc(size);
	if (!btf->data)
		goto errout;
	btf->data_size = size;
	if (copy_from_user(btf->data, ubtf, size)) {
		err = -EFAULT;
		goto errout;
	}

	err = btf_check_hdr(env, size);
	if (err)
		goto errout;

	/* every type takes at least sizeof(struct btf_type) bytes */
	env->max_types = btf->hdr.type_len / sizeof(struct btf_type);
	if (env->max_types > BTF_MAX_TYPE)
		env->max_types = BTF_MAX_TYPE;
	n = (size_t)env->max_types + 1;

	err = -ENOMEM;
	btf->type_off = vzalloc(n * sizeof(u32));
	btf->rsize = vzalloc(n * sizeof(u32));
	env->state = vzalloc(n);
	if (!btf->type_off || !btf->rsize || !env->state)
		goto errout;

	err = btf_check_all_metas(env);
	if (err)
		goto errout;
	err = btf_resolve_all(env);
	if (err)
		goto errout;

	vfree(env->state);
	env->state = NULL;
	return btf;

errout:
	vfree(env->state);
	env->state = NULL;
	btf_free(btf);
	return ERR_PTR(err);
}

int btf_new_fd(const union bpf_attr *attr)
{
	void __user *ubtf = (void __user *)(unsigned long)attr->btf;
	void __user *ulog = (void __user *)(unsigned long)attr->btf_log_buf;
	struct btf_env env = {};
	struct btf *btf;
	int fd, err = 0;

	/* Upstream: BTF load is a privileged operation. */
	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;
	if (attr->btf_size == 0)
		return -EINVAL;
	if (attr->btf_size > BPF_BTF_MAX_SIZE)
		return -E2BIG;

	if (attr->btf_log_level) {
		if (!ulog || !attr->btf_log_size)
			return -EINVAL;
		env.log.level = attr->btf_log_level;
		env.log.size = min_t(u32, attr->btf_log_size, BTF_LOG_MAX);
		env.log.kbuf = vzalloc(env.log.size);
		if (!env.log.kbuf)
			return -ENOMEM;
	}

	btf = btf_parse(&env, ubtf, attr->btf_size);
	if (IS_ERR(btf))
		err = PTR_ERR(btf);

	if (env.log.kbuf) {
		/* len <= size - 1, so the NUL always fits */
		env.log.kbuf[env.log.len] = 0;
		if (copy_to_user(ulog, env.log.kbuf, env.log.len + 1)) {
			if (!err) {
				btf_put(btf);
				err = -EFAULT;
			}
		}
		vfree(env.log.kbuf);
	}
	if (err)
		return err;

	btf->id = (u32)atomic_inc_return(&btf_id_gen);
	fd = anon_inode_getfd("btf", &btf_fops, btf, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		btf_put(btf);
	return fd;
}

int btf_get_info_by_fd(const struct btf *btf, const union bpf_attr *attr,
		       union bpf_attr __user *uattr)
{
	struct bpf_btf_info __user *uinfo;
	struct bpf_btf_info info = {};
	u32 info_copy, btf_copy;
	void __user *ubtf;
	u32 uinfo_len;

	uinfo = (struct bpf_btf_info __user *)(unsigned long)attr->info.info;
	uinfo_len = attr->info.info_len;

	info_copy = min_t(u32, uinfo_len, sizeof(info));
	if (copy_from_user(&info, uinfo, info_copy))
		return -EFAULT;

	info.id = btf->id;
	ubtf = (void __user *)(unsigned long)info.btf;
	btf_copy = min_t(u32, btf->data_size, info.btf_size);
	if (ubtf && btf_copy && copy_to_user(ubtf, btf->data, btf_copy))
		return -EFAULT;
	info.btf_size = btf->data_size;

	if (copy_to_user(uinfo, &info, info_copy) ||
	    put_user(info_copy, &uattr->info.info_len))
		return -EFAULT;
	return 0;
}

/* ---------------------------------------------------------------------- */
/* Consumers: map key/value types and program func_info/line_info         */
/* ---------------------------------------------------------------------- */

int btf_type_size(const struct btf *btf, u32 type_id)
{
	const struct btf_type *t;
	u32 size;

	if (!type_id || type_id > btf->nr_types)
		return -EINVAL;
	t = btf_type_by_id(btf, type_id);
	if (btf_kind_is_no_target(btf_kind(t)))
		return -EINVAL;
	size = btf->rsize[type_id];
	if (size == BTF_SZ_NONE || size > INT_MAX)
		return -EINVAL;
	return size;
}

int btf_check_map_kv(const struct btf *btf, u32 key_type_id, u32 key_size,
		     u32 value_type_id, u32 value_size)
{
	int sz;

	/* Same contract as upstream map_check_btf(): both types must exist,
	 * have a size, and that size must equal the map's key/value size.
	 */
	sz = btf_type_size(btf, key_type_id);
	if (sz < 0 || (u32)sz != key_size)
		return -EINVAL;
	sz = btf_type_size(btf, value_type_id);
	if (sz < 0 || (u32)sz != value_size)
		return -EINVAL;
	return 0;
}

#define BPF_FUNCINFO_MIN_SIZE	8
#define BPF_LINEINFO_MIN_SIZE	16
#define BPF_INFO_REC_MAX_SIZE	252

struct bpf_func_info_rec {
	__u32 insn_off;
	__u32 type_id;
};

struct bpf_line_info_rec {
	__u32 insn_off;
	__u32 file_name_off;
	__u32 line_off;
	__u32 line_col;
};

/* Bytes [known, rec_size) of a user record must be zero. */
static int btf_user_rec_tail_zero(const void __user *rec, u32 known,
				  u32 rec_size)
{
	u32 i;
	u8 b;

	for (i = known; i < rec_size; i++) {
		if (get_user(b, (const u8 __user *)rec + i))
			return -EFAULT;
		if (b)
			return -E2BIG;
	}
	return 0;
}

static int btf_check_func_info(const struct btf *btf,
			       const union bpf_attr *attr, u32 prog_len)
{
	void __user *ufunc = (void __user *)(unsigned long)attr->func_info;
	u32 rec_size = attr->func_info_rec_size;
	struct bpf_func_info_rec rec;
	const struct btf_type *t;
	int err;

	if (!attr->func_info_cnt)
		return 0;
	if (rec_size < BPF_FUNCINFO_MIN_SIZE || rec_size > BPF_INFO_REC_MAX_SIZE ||
	    (rec_size & 3))
		return -EINVAL;
	/* This verifier has no BPF-to-BPF calls, hence exactly one function:
	 * the program itself, starting at instruction 0.
	 */
	if (attr->func_info_cnt != 1 || !prog_len)
		return -EINVAL;

	err = btf_user_rec_tail_zero(ufunc, sizeof(rec), rec_size);
	if (err)
		return err;
	if (copy_from_user(&rec, ufunc, sizeof(rec)))
		return -EFAULT;
	if (rec.insn_off != 0)
		return -EINVAL;
	t = btf_type_by_id(btf, rec.type_id);
	if (!rec.type_id || !t || btf_kind(t) != BTF_KIND_FUNC)
		return -EINVAL;
	return 0;
}

static int btf_check_line_info(const struct btf *btf,
			       const union bpf_attr *attr, u32 prog_len)
{
	void __user *uline = (void __user *)(unsigned long)attr->line_info;
	u32 rec_size = attr->line_info_rec_size;
	u32 cnt = attr->line_info_cnt, i, prev = 0;
	struct bpf_line_info_rec rec;
	int err;

	if (!cnt)
		return 0;
	if (rec_size < BPF_LINEINFO_MIN_SIZE || rec_size > BPF_INFO_REC_MAX_SIZE ||
	    (rec_size & 3))
		return -EINVAL;
	if (cnt > prog_len)
		return -EINVAL;

	for (i = 0; i < cnt; i++) {
		const void __user *urec = uline + (size_t)i * rec_size;

		err = btf_user_rec_tail_zero(urec, sizeof(rec), rec_size);
		if (err)
			return err;
		if (copy_from_user(&rec, urec, sizeof(rec)))
			return -EFAULT;
		if (i == 0 && rec.insn_off != 0)
			return -EINVAL;
		if (i && rec.insn_off <= prev)
			return -EINVAL;
		if (rec.insn_off >= prog_len)
			return -EINVAL;
		if (!btf_name_offset_valid(btf, rec.file_name_off) ||
		    !btf_name_offset_valid(btf, rec.line_off))
			return -EINVAL;
		prev = rec.insn_off;
	}
	return 0;
}

int btf_check_prog_info(const union bpf_attr *attr, u32 prog_len)
{
	struct btf *btf;
	int err;

	if (!attr->func_info_cnt && !attr->line_info_cnt) {
		if (attr->func_info_rec_size || attr->line_info_rec_size)
			return -EINVAL;
		return 0;
	}

	btf = btf_get_by_fd(attr->prog_btf_fd);
	if (IS_ERR(btf))
		return PTR_ERR(btf);

	err = btf_check_func_info(btf, attr, prog_len);
	if (!err)
		err = btf_check_line_info(btf, attr, prog_len);
	btf_put(btf);
	return err;
}
