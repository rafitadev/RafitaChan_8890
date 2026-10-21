/* SPDX-License-Identifier: GPL-2.0 */
/* Copyright (c) 2018 Facebook */
#ifndef _LINUX_BTF_H
#define _LINUX_BTF_H 1

#include <linux/types.h>
#include <uapi/linux/btf.h>

union bpf_attr;

struct btf;
struct btf_type;

/* Max size of a BTF blob accepted by BPF_BTF_LOAD */
#define BPF_BTF_MAX_SIZE	(16 * 1024 * 1024)

#ifdef CONFIG_BPF_SYSCALL
const struct btf_type *btf_type_by_id(const struct btf *btf, u32 type_id);
const char *btf_name_by_offset(const struct btf *btf, u32 offset);
struct btf *btf_get_by_fd(int fd);
void btf_put(struct btf *btf);

/* BPF_BTF_LOAD: parse and validate a BTF blob, return an fd or -errno */
int btf_new_fd(const union bpf_attr *attr);
/* BPF_OBJ_GET_INFO_BY_FD for a BTF fd */
int btf_get_info_by_fd(const struct btf *btf, const union bpf_attr *attr,
		       union bpf_attr __user *uattr);

/* Size (in bytes) of type_id after skipping modifiers/typedefs, or a
 * negative errno if the type does not exist or has no size (void, fwd, ...).
 */
int btf_type_size(const struct btf *btf, u32 type_id);

/* BPF_MAP_CREATE: check btf_key_type_id/btf_value_type_id against the map's
 * key_size/value_size.
 */
int btf_check_map_kv(const struct btf *btf, u32 key_type_id, u32 key_size,
		     u32 value_type_id, u32 value_size);

/* BPF_PROG_LOAD: validate prog_btf_fd/func_info/line_info. */
int btf_check_prog_info(const union bpf_attr *attr, u32 prog_len);
#endif

#endif
