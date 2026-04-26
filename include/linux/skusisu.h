/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_SKUSISU_H
#define _LINUX_SKUSISU_H

/*
 * Sukisu integration marker header.
 *
 * Kept lightweight on purpose: downstream hooks live in KernelSU core files
 * and VFS call sites. This header provides a single compile-time feature
 * marker for follow-up patches without introducing extra dependencies.
 */
#define CONFIG_SKUSISU_INTEGRATION 1

#endif /* _LINUX_SKUSISU_H */
