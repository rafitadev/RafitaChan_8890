// SPDX-License-Identifier: GPL-2.0
/*
 * Minimal OPLUS/ColorOS health information procfs compatibility interface.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/swap.h>
#include <linux/uaccess.h>

#define OPLUS_HEALTHINFO_DIR	"oplus_healthinfo"
#define OPLUS_SWAPPINESS_MAX	200

static struct proc_dir_entry *oplus_healthinfo_dir;

/*
 * oplus_healthinfo_iowait_read() - report the number of active I/O waiters.
 *
 * nr_iowait() sums scheduler runqueue I/O wait counters across all CPUs.  The
 * value is instantaneous, rather than a cumulative CPU-time value, and is the
 * same unit exposed by the kernel's scheduler accounting.
 */
static ssize_t oplus_healthinfo_iowait_read(struct file *file,
					    char __user *buf, size_t count,
					    loff_t *ppos)
{
	char value[24];
	int len;

	len = scnprintf(value, sizeof(value), "%lu\n", nr_iowait());
	return simple_read_from_buffer(buf, count, ppos, value, len);
}

/*
 * oplus_healthinfo_swappiness_read() - return the active global swappiness.
 */
static ssize_t oplus_healthinfo_swappiness_read(struct file *file,
						char __user *buf, size_t count,
						loff_t *ppos)
{
	char value[16];
	int len;

	len = scnprintf(value, sizeof(value), "%d\n", vm_swappiness);
	return simple_read_from_buffer(buf, count, ppos, value, len);
}

/*
 * oplus_healthinfo_swappiness_write() - validate and set global swappiness.
 *
 * The accepted range follows this tree's vm.swappiness sysctl upper bound.
 * Invalid input leaves vm_swappiness unchanged and returns -EINVAL.
 */
static ssize_t oplus_healthinfo_swappiness_write(struct file *file,
						 const char __user *buf,
						 size_t count, loff_t *ppos)
{
	char value[16];
	int swappiness;

	if (!count || count >= sizeof(value))
		return -EINVAL;
	if (copy_from_user(value, buf, count))
		return -EFAULT;
	value[count] = '\0';

	if (kstrtoint(strim(value), 0, &swappiness) ||
	    swappiness < 0 || swappiness > OPLUS_SWAPPINESS_MAX)
		return -EINVAL;

	vm_swappiness = swappiness;
	return count;
}

static const struct file_operations oplus_healthinfo_iowait_fops = {
	.owner = THIS_MODULE,
	.read = oplus_healthinfo_iowait_read,
	.llseek = default_llseek,
};

static const struct file_operations oplus_healthinfo_swappiness_fops = {
	.owner = THIS_MODULE,
	.read = oplus_healthinfo_swappiness_read,
	.write = oplus_healthinfo_swappiness_write,
	.llseek = default_llseek,
};

/*
 * oplus_healthinfo_init() - create the OPLUS-compatible procfs hierarchy.
 */
static int __init oplus_healthinfo_init(void)
{
	oplus_healthinfo_dir = proc_mkdir(OPLUS_HEALTHINFO_DIR, NULL);
	if (!oplus_healthinfo_dir)
		return -ENOMEM;

	if (!proc_create("iowait", 0444, oplus_healthinfo_dir,
			 &oplus_healthinfo_iowait_fops) ||
	    !proc_create("swappiness_para", 0644, oplus_healthinfo_dir,
			 &oplus_healthinfo_swappiness_fops)) {
		remove_proc_subtree(OPLUS_HEALTHINFO_DIR, NULL);
		oplus_healthinfo_dir = NULL;
		return -ENOMEM;
	}

	return 0;
}

/*
 * oplus_healthinfo_exit() - remove all procfs entries created by this module.
 */
static void __exit oplus_healthinfo_exit(void)
{
	if (oplus_healthinfo_dir)
		remove_proc_subtree(OPLUS_HEALTHINFO_DIR, NULL);
}

module_init(oplus_healthinfo_init);
module_exit(oplus_healthinfo_exit);

MODULE_DESCRIPTION("Minimal OPLUS health information procfs interface");
MODULE_LICENSE("GPL v2");
