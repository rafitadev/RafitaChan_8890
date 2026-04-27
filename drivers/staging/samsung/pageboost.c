// SPDX-License-Identifier: GPL-2.0
/*
 * Samsung Pageboost backport (Exynos 9810 -> Exynos 8890/3.18)
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/mm.h>
#include <linux/dcache.h>
#include <linux/slab.h>
#include <linux/workqueue.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/sched.h>
#include <linux/pid.h>
#include <linux/ioprio.h>
#include <linux/iocontext.h>
#include <linux/fdtable.h>
#include <linux/string.h>
#include <linux/tracepoint.h>
#include <trace/events/sched.h>

#define PB_PREFETCH_BYTES		(2 * 1024 * 1024)
#define PB_PREFETCH_CHUNK		(PAGE_SIZE * 8)
#define PB_MAX_VISITS			256
#define PB_MAX_MMAP_SCAN		32

struct pb_visit_entry {
	char path[96];
	u32 hits;
};

struct pb_exec_work {
	struct work_struct work;
	pid_t pid;
	char exec_path[128];
};

static struct pb_visit_entry pb_visits[PB_MAX_VISITS];
static DEFINE_SPINLOCK(pb_visit_lock);
static struct workqueue_struct *pb_wq;
static struct delayed_work pb_boot_prefetch_work;
static struct kobject *pb_kobj;

static int pageboost_active = 1;
static int pageboost_record = 1;

#ifdef CONFIG_PAGEBOOST_DEBUG
#define pb_dbg(fmt, ...) pr_info("pageboost: " fmt, ##__VA_ARGS__)
#else
#define pb_dbg(fmt, ...) do { } while (0)
#endif

static bool pb_is_hot_file(const char *path)
{
	if (!path)
		return false;

	return strnstr(path, ".dex", PATH_MAX) ||
	       strnstr(path, ".odex", PATH_MAX) ||
	       strnstr(path, ".vdex", PATH_MAX) ||
	       strnstr(path, ".oat", PATH_MAX) ||
	       strnstr(path, ".so", PATH_MAX);
}

static void pb_record_visit(const char *path)
{
	unsigned long flags;
	u32 idx;
	u32 free_idx = PB_MAX_VISITS;

	if (!pageboost_record || !path)
		return;

	idx = full_name_hash(path, strnlen(path, PATH_MAX)) % PB_MAX_VISITS;

	spin_lock_irqsave(&pb_visit_lock, flags);
	if (!pb_visits[idx].path[0]) {
		strlcpy(pb_visits[idx].path, path, sizeof(pb_visits[idx].path));
		pb_visits[idx].hits = 1;
		spin_unlock_irqrestore(&pb_visit_lock, flags);
		return;
	}

	if (!strncmp(pb_visits[idx].path, path, sizeof(pb_visits[idx].path))) {
		pb_visits[idx].hits++;
		spin_unlock_irqrestore(&pb_visit_lock, flags);
		return;
	}

	for (idx = 0; idx < PB_MAX_VISITS; idx++) {
		if (!strncmp(pb_visits[idx].path, path, sizeof(pb_visits[idx].path))) {
			pb_visits[idx].hits++;
			spin_unlock_irqrestore(&pb_visit_lock, flags);
			return;
		}
		if (free_idx == PB_MAX_VISITS && !pb_visits[idx].path[0])
			free_idx = idx;
	}

	if (free_idx < PB_MAX_VISITS) {
		strlcpy(pb_visits[free_idx].path, path, sizeof(pb_visits[free_idx].path));
		pb_visits[free_idx].hits = 1;
	}
	spin_unlock_irqrestore(&pb_visit_lock, flags);
}

#ifdef CONFIG_PAGEBOOST_IO_BOOST
static void pb_set_task_ioboost(pid_t pid, bool boost, int *saved_ioprio)
{
	struct task_struct *tsk;
	int ioprio = IOPRIO_PRIO_VALUE(IOPRIO_CLASS_RT, 0);

	if (pid <= 0)
		return;

	rcu_read_lock();
	tsk = find_task_by_vpid(pid);
	if (tsk)
		get_task_struct(tsk);
	rcu_read_unlock();
	if (!tsk)
		return;

	if (boost) {
		*saved_ioprio = IOPRIO_PRIO_VALUE(IOPRIO_CLASS_BE, IOPRIO_NORM);
		task_lock(tsk);
		if (tsk->io_context)
			*saved_ioprio = tsk->io_context->ioprio;
		task_unlock(tsk);
		set_task_ioprio(tsk, ioprio);
	} else if (saved_ioprio) {
		set_task_ioprio(tsk, *saved_ioprio);
	}

	put_task_struct(tsk);
}
#else
static void pb_set_task_ioboost(pid_t pid, bool boost, int *saved_ioprio) { }
#endif

static void pb_prefetch_file(const char *path, pid_t pid)
{
	struct file *filp;
	char *buf;
	loff_t pos = 0;
	ssize_t ret;
	size_t remaining = PB_PREFETCH_BYTES;
	int saved_ioprio = IOPRIO_PRIO_VALUE(IOPRIO_CLASS_BE, IOPRIO_NORM);

	if (!path || !pb_is_hot_file(path))
		return;

	filp = filp_open(path, O_RDONLY | O_LARGEFILE, 0);
	if (IS_ERR(filp))
		return;

	buf = kmalloc(PB_PREFETCH_CHUNK, GFP_KERNEL);
	if (!buf) {
		filp_close(filp, NULL);
		return;
	}

	pb_set_task_ioboost(pid, true, &saved_ioprio);

	while (remaining) {
		size_t step = min_t(size_t, remaining, PB_PREFETCH_CHUNK);

		ret = kernel_read(filp, pos, buf, step);
		if (ret <= 0)
			break;
		pos += ret;
		remaining -= ret;
		cond_resched();
	}

	pb_set_task_ioboost(pid, false, &saved_ioprio);
	pb_record_visit(path);
	pb_dbg("prefetched %s (%lld bytes)\n", path, pos);

	kfree(buf);
	filp_close(filp, NULL);
}

static void pb_prefetch_from_mm(pid_t pid)
{
	struct task_struct *tsk;
	struct mm_struct *mm;
	struct vm_area_struct *vma;
	int scanned = 0;
	char *tmp;

	rcu_read_lock();
	tsk = find_task_by_vpid(pid);
	if (tsk)
		get_task_struct(tsk);
	rcu_read_unlock();
	if (!tsk)
		return;

	mm = get_task_mm(tsk);
	put_task_struct(tsk);
	if (!mm)
		return;

	tmp = kmalloc(PATH_MAX, GFP_KERNEL);
	if (!tmp) {
		mmput(mm);
		return;
	}

	down_read(&mm->mmap_sem);
	for (vma = mm->mmap; vma && scanned < PB_MAX_MMAP_SCAN; vma = vma->vm_next) {
		char *name;
		if (!vma->vm_file)
			continue;
		name = d_path(&vma->vm_file->f_path, tmp, PATH_MAX);
		if (IS_ERR(name))
			continue;
		if (!pb_is_hot_file(name))
			continue;
		pb_prefetch_file(name, pid);
		scanned++;
	}
	up_read(&mm->mmap_sem);

	kfree(tmp);
	mmput(mm);
}

static void pb_exec_worker(struct work_struct *work)
{
	struct pb_exec_work *ew = container_of(work, struct pb_exec_work, work);

	if (pageboost_active) {
		pb_prefetch_file(ew->exec_path, ew->pid);
		pb_prefetch_from_mm(ew->pid);
	}

	kfree(ew);
}

static void pb_sched_process_exec(void *ignore, struct task_struct *p,
		pid_t old_pid, struct linux_binprm *bprm)
{
	struct pb_exec_work *ew;
	char *tmp, *name;

	if (!pageboost_active || !pb_wq || !bprm || !bprm->file)
		return;

	tmp = kmalloc(PATH_MAX, GFP_ATOMIC);
	if (!tmp)
		return;

	name = d_path(&bprm->file->f_path, tmp, PATH_MAX);
	if (IS_ERR(name)) {
		kfree(tmp);
		return;
	}

	ew = kzalloc(sizeof(*ew), GFP_ATOMIC);
	if (!ew) {
		kfree(tmp);
		return;
	}

	ew->pid = task_pid_nr(p);
	strlcpy(ew->exec_path, name, sizeof(ew->exec_path));
	INIT_WORK(&ew->work, pb_exec_worker);
	queue_work(pb_wq, &ew->work);

	kfree(tmp);
}

static void pb_boot_prefetch_worker(struct work_struct *work)
{
	static const char * const boot_hot_files[] = {
		"/system/framework/boot-framework.oat",
		"/system/framework/arm64/boot-framework.oat",
		"/system/framework/oat/arm64/services.vdex",
		"/system/lib64/libart.so",
		"/system/lib64/libhwui.so",
		"/system/lib64/libskia.so",
	};
	int i;

	if (!pageboost_active)
		return;

	for (i = 0; i < ARRAY_SIZE(boot_hot_files); i++)
		pb_prefetch_file(boot_hot_files[i], 0);
}

static ssize_t pageboost_active_show(struct kobject *kobj,
		struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%d\n", pageboost_active);
}

static ssize_t pageboost_active_store(struct kobject *kobj,
		struct kobj_attribute *attr, const char *buf, size_t count)
{
	int val;

	if (kstrtoint(buf, 0, &val))
		return -EINVAL;
	pageboost_active = !!val;
	return count;
}

static ssize_t pageboost_record_show(struct kobject *kobj,
		struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%d\n", pageboost_record);
}

static ssize_t pageboost_record_store(struct kobject *kobj,
		struct kobj_attribute *attr, const char *buf, size_t count)
{
	int val;

	if (kstrtoint(buf, 0, &val))
		return -EINVAL;
	pageboost_record = !!val;
	return count;
}

static struct kobj_attribute pageboost_active_attr =
	__ATTR(pageboost_active, 0644, pageboost_active_show, pageboost_active_store);
static struct kobj_attribute pageboost_record_attr =
	__ATTR(pageboost_record, 0644, pageboost_record_show, pageboost_record_store);

static struct attribute *pb_attrs[] = {
	&pageboost_active_attr.attr,
	&pageboost_record_attr.attr,
	NULL,
};

static const struct attribute_group pb_attr_group = {
	.attrs = pb_attrs,
};

static int __init pageboost_init(void)
{
	int ret;

	pb_wq = alloc_workqueue("pageboost_wq", WQ_UNBOUND | WQ_HIGHPRI, 1);
	if (!pb_wq)
		return -ENOMEM;

	pb_kobj = kobject_create_and_add("pageboost", kernel_kobj);
	if (!pb_kobj) {
		destroy_workqueue(pb_wq);
		return -ENOMEM;
	}

	ret = sysfs_create_group(pb_kobj, &pb_attr_group);
	if (ret) {
		kobject_put(pb_kobj);
		destroy_workqueue(pb_wq);
		return ret;
	}

	ret = register_trace_sched_process_exec(pb_sched_process_exec, NULL);
	if (ret) {
		sysfs_remove_group(pb_kobj, &pb_attr_group);
		kobject_put(pb_kobj);
		destroy_workqueue(pb_wq);
		return ret;
	}

	INIT_DELAYED_WORK(&pb_boot_prefetch_work, pb_boot_prefetch_worker);
	queue_delayed_work(pb_wq, &pb_boot_prefetch_work, msecs_to_jiffies(25000));

	pr_info("pageboost: initialized\n");
	return 0;
}

static void __exit pageboost_exit(void)
{
	unregister_trace_sched_process_exec(pb_sched_process_exec, NULL);
	cancel_delayed_work_sync(&pb_boot_prefetch_work);
	if (pb_wq)
		destroy_workqueue(pb_wq);
	if (pb_kobj) {
		sysfs_remove_group(pb_kobj, &pb_attr_group);
		kobject_put(pb_kobj);
	}
}

late_initcall(pageboost_init);
module_exit(pageboost_exit);

MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("Samsung Pageboost backport for Exynos8890 kernel 3.18");
