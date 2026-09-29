#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Exercise the actual KGSL accounting/lifetime functions with host primitives."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[4]
source = (ROOT / 'drivers/gpu/msm/kgsl.c').read_text()
def function(name):
    start = source.index(name + '(')
    start = source.rfind('\n', 0, start) + 1
    a = source.index('{', start)
    depth, end = 1, a + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
header = (ROOT / 'drivers/gpu/msm/kgsl.h').read_text()
a = header.index('struct gpu_work_period {')
b = header.index('\nstruct kgsl_device;', a)
structs = header[a:b]
prelude = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
typedef uint64_t u64;
typedef uint32_t u32;
typedef unsigned uid_t;
typedef struct { int value; } atomic_t;
struct kref { int refs; };
struct list_head { struct list_head *next,*prev; };
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define LIST_HEAD(n) struct list_head n={&n,&n}
#define INIT_LIST_HEAD(p) do { (p)->next=(p); (p)->prev=(p); } while(0)
#define list_empty(p) ((p)->next==(p))
static void list_add(struct list_head *p,struct list_head *h) {
 p->next=h->next;p->prev=h;h->next->prev=p;h->next=p;
}
static void list_del_init(struct list_head *p) {
 p->prev->next=p->next;p->next->prev=p->prev;INIT_LIST_HEAD(p);
}
#define list_for_each_entry(p,h,m) \
 for(p=container_of((h)->next,__typeof__(*p),m); &(p)->m!=(h); p=container_of(p->m.next,__typeof__(*p),m))
#define list_for_each_entry_safe(p,n,h,m) \
 for(p=container_of((h)->next,__typeof__(*p),m),n=container_of(p->m.next,__typeof__(*p),m); \
 &(p)->m!=(h); p=n,n=container_of(n->m.next,__typeof__(*n),m))
static int allocations, fail_alloc;
static void *kzalloc(size_t n,int flags) { (void)flags;if(fail_alloc)return NULL;allocations++;return calloc(1,n); }
static void kfree(void *p) { allocations--;free(p); }
#define GFP_ATOMIC 0
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define IS_ERR_OR_NULL(p) (!(p)||(uintptr_t)(p)>=(uintptr_t)-4095)
static void kref_init(struct kref *p) { p->refs=1; }
static void kref_get(struct kref *p) { assert(p->refs>0);p->refs++; }
static int kref_get_unless_zero(struct kref *p) { if(!p->refs)return 0;p->refs++;return 1; }
static void kref_put(struct kref *p,void (*release)(struct kref *)) { assert(p->refs>0);if(!--p->refs)release(p); }
static void atomic_inc(atomic_t *p) { p->value++; }
static void atomic_dec(atomic_t *p) { assert(p->value>0);p->value--; }
#define atomic_read(p) ((p)->value)
static void spin_lock(int *p) { assert(!*p);*p=1; }
static void spin_unlock(int *p) { assert(*p);*p=0; }
#define test_bit(b,p) (!!(*(p)&(1ul<<(b))))
#define __clear_bit(b,p) (*(p)&=~(1ul<<(b)))
static bool __test_and_set_bit(int b,unsigned long *p) { bool old=test_bit(b,p);*p|=1ul<<b;return old; }
static bool __test_and_clear_bit(int b,unsigned long *p) { bool old=test_bit(b,p);__clear_bit(b,p);return old; }
#define do_div(n,d) ((n)/=(d))
#define min_t(t,a,b) ((t)(a)<(t)(b)?(t)(a):(t)(b))
#define smp_wmb() do {} while(0)
struct work_struct { int unused; };
struct timer_list { bool pending; };
struct kgsl_device {
 struct work_struct work_period_ws; int work_period_lock;
 struct timer_list work_period_timer;
 bool work_period_running,work_period_stopping;u64 work_period_begin;
};
static struct {struct list_head wp_list;int wp_list_lock;} kgsl_driver;
static u64 now,jiffies;
#define ktime_get_ns() now
#define msecs_to_jiffies(ms) (ms)
static void mod_timer(struct timer_list *t,u64 expires) { (void)expires;t->pending=true; }
static void del_timer_sync(struct timer_list *t) { t->pending=false; }
static void cancel_work_sync(struct work_struct *w) { (void)w; }
struct event {u32 gpu,uid;u64 start,end,active;};
static struct event events[16];static int count;
static void trace_gpu_work_period(u32 gpu,u32 uid,u64 start,u64 end,u64 active) {
 assert(count<16);assert(end>start);assert(active>0&&active<=end-start);
 events[count++]=(struct event){gpu,uid,start,end,active};
}
#define KGSL_GPU_ID 1
'''
main = r'''
int main(void) {
 struct kgsl_device dev={0};
 INIT_LIST_HEAD(&kgsl_driver.wp_list);
 fail_alloc=1;assert(IS_ERR_OR_NULL(kgsl_get_work_period(1)));fail_alloc=0;
 struct gpu_work_period *p=kgsl_get_work_period(10000),*q=kgsl_get_work_period(10000);
 assert(p==q&&p->refcount.refs==2&&allocations==1);
 now=1000000000;kgsl_work_period_start(&dev,p);
 kgsl_work_period_start(&dev,q);
 assert(p->refcount.refs==3&&atomic_read(&p->active_cmds)==2);
 kgsl_work_period_update(&dev,p,1920000); /* 100ms */
 kgsl_work_period_update(&dev,q,3840000); /* 200ms */
 atomic_dec(&p->active_cmds);atomic_dec(&p->active_cmds);
 kgsl_put_work_period(q);kgsl_put_work_period(p);
 assert(allocations==1); /* Reporting reference outlives the processes. */
 now+=900000000;_log_gpu_work_events(&dev.work_period_ws);
 assert(allocations==0&&count==1&&events[0].active==300000000);
 assert(events[0].uid==10000&&!dev.work_period_running);
 p=kgsl_get_work_period(10001);q=kgsl_get_work_period(10002);
 kgsl_work_period_start(&dev,p);kgsl_work_period_start(&dev,q);
 kgsl_work_period_update(&dev,p,192000);kgsl_work_period_update(&dev,q,384000);
 now+=900000000;_log_gpu_work_events(&dev.work_period_ws);
 assert(count==3&&dev.work_period_running);
 assert(events[1].uid!=events[2].uid&&events[1].start==events[2].start);
 assert(p->active==0&&q->active==0);
 kgsl_work_period_update(&dev,p,192000);
 now+=900000000;_log_gpu_work_events(&dev.work_period_ws);
 assert(count==4&&events[3].start==events[1].end&&events[3].active==10000000);
 atomic_dec(&p->active_cmds);atomic_dec(&q->active_cmds);
 kgsl_put_work_period(p);kgsl_put_work_period(q);
 kgsl_work_period_close(&dev);
 assert(allocations==0&&list_empty(&kgsl_driver.wp_list));
 puts("PASS: UID sharing, accumulation, successive periods, allocation failure, process exit and teardown");
}
'''
names = ['kgsl_work_period_release', 'kgsl_put_work_period', 'kgsl_work_period_update',
         '_log_gpu_work_events', 'kgsl_get_work_period', 'kgsl_work_period_start', 'kgsl_work_period_close']
with tempfile.TemporaryDirectory() as temp:
    path = pathlib.Path(temp) / 'check.c'
    path.write_text(prelude + structs + '\n' + '\n'.join(function(n) for n in names) + main)
    exe = pathlib.Path(temp) / 'check'
    subprocess.run(['clang', '-std=gnu11', '-Wall', '-Werror', '-fsanitize=address,undefined', str(path), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
