// SPDX-License-Identifier: GPL-2.0
#include <linux/kernel.h>
#include <linux/init.h>

/* Optional SUSFS shim (disabled by default via CONFIG_KSU_SUSFS=n). */
static int __init susfs_stub_init(void)
{
	pr_info("susfs stub loaded (compat mode)\n");
	return 0;
}

late_initcall(susfs_stub_init);
