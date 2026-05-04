#ifndef __LINUX_KBUILD_H
#define __LINUX_KBUILD_H

#ifdef __clang__
#define DEFINE(sym, val) \
	asm volatile("\n.ascii \"->" #sym " %0 " #val "\"" : : "i" (val))
#define BLANK() asm volatile("\n.ascii \"->\"")
#define COMMENT(x) \
	asm volatile("\n.ascii \"->#" x "\"")
#else
#define DEFINE(sym, val) \
        asm volatile("\n->" #sym " %0 " #val : : "i" (val))
#define BLANK() asm volatile("\n->" : : )
#define COMMENT(x) \
	asm volatile("\n->#" x)
#endif

#define OFFSET(sym, str, mem) \
	DEFINE(sym, offsetof(struct str, mem))

#endif
