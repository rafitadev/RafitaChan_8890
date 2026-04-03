// SPDX-License-Identifier: GPL-2.0
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/types.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/cred.h>

bool ksu_vfs_read_hook __read_mostly;
bool ksu_execveat_hook __read_mostly;
bool ksu_input_hook __read_mostly;
bool ksu_layout_independent_mode __read_mostly = true;

int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
		size_t *count_ptr, loff_t **pos) { return 0; }
int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
		void *envp, int *flags) { return 0; }
int ksu_handle_execve(int *fd, struct filename **filename_ptr, void *argv,
		void *envp, int *flags)
{
	/* Treble/OneUI/GSI-safe wrapper: keep hook independent of partition layout. */
	return ksu_handle_execveat(fd, filename_ptr, argv, envp, flags);
}
int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
		void *argv, void *envp, int *flags) { return 0; }
int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,
		int *flags) { return 0; }
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags) { return 0; }
int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code,
		int *value) { return 0; }
int ksu_handle_mount(char **dev_name, const char __user **dir_name,
		char **type, unsigned long *flags, unsigned long *data_page) { return 0; }
int ksu_safe_mount_wrapper(char **dev_name, const char __user **dir_name,
		char **type, unsigned long *flags, unsigned long *data_page)
{
	/* Treble/OneUI/GSI-safe wrapper: avoid vendor-specific path assumptions. */
	return ksu_handle_mount(dev_name, dir_name, type, flags, data_page);
}
int ksu_handle_commit_creds(struct cred *new, const struct cred *old) { return 0; }
int ksu_handle_proc_pid_permission(struct inode *inode, int *mask) { return 0; }
int ksu_handle_user_path_at(int *dfd, const char __user **name, unsigned *flags) { return 0; }
int ksu_safe_user_path_wrapper(int *dfd, const char __user **name, unsigned *flags)
{
	/* Treble/OneUI/GSI-safe wrapper: use VFS-level path interception only. */
	return ksu_handle_user_path_at(dfd, name, flags);
}

static int __init ksu_core_init(void)
{
	pr_info("KernelSU compat core initialized (safe/no-op mode)\n");
	return 0;
}
late_initcall(ksu_core_init);
