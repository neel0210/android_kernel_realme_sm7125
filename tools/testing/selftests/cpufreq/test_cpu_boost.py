#!/usr/bin/env python3
"""Run the actual touch-boost workers against a refcounted scheduler model."""
import pathlib
import re
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[4]
source = (root/'drivers/cpufreq/cpu-boost.c').read_text()
active = re.search(r'static \w+(?: \w+)? sched_boost_active;', source).group()
workers = source[source.index('static void do_input_boost_rem('):
                 source.index('static void cpuboost_input_event(')]
code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <limits.h>
struct work_struct { int unused; };
struct cpu_sync { unsigned int input_boost_freq, input_boost_min; };
static struct cpu_sync sync_info[2]={{1248000,0},{1555200,0}};
static unsigned int sched_boost_on_input=2, input_boost_ms=80;
static int refs[4], input_boost_rem, cpu_boost_wq;
#define READ_ONCE(x) (x)
#define per_cpu(array,i) array[i]
#define for_each_possible_cpu(i) for(i=0;i<2;i++)
#define pr_debug(...) ((void)0)
#define pr_err(...) ((void)0)
#define cancel_delayed_work_sync(p) ((void)(p))
#define msecs_to_jiffies(ms) (ms)
#define queue_delayed_work(w,p,t) ((void)(w),(void)(p),(void)(t))
static void update_policy_online(void) {}
static int sched_set_boost(int type) {
 if (type==0) { refs[1]=refs[2]=refs[3]=0; return 0; }
 if (type < -3 || type > 3) return -1;
 if (type>0) refs[type]++;
 else if (refs[-type]) refs[-type]--;
 return 0;
}
'''
main = r'''
int main(void) {
 struct work_struct work={0};
 refs[1]=1; refs[2]=1; /* Other clients' full and conservative boosts. */
 do_input_boost(&work);
 assert(refs[1]==1 && refs[2]==2);
 assert(sync_info[1].input_boost_min==1555200);
 sched_boost_on_input=1; /* Setting changes while our old request is active. */
 do_input_boost(&work);
 assert(refs[1]==2 && refs[2]==1);
 do_input_boost_rem(&work);
 assert(refs[1]==1 && refs[2]==1);
 assert(sync_info[0].input_boost_min==0 && sync_info[1].input_boost_min==0);
 sched_boost_on_input=99; /* Failed requests must not acquire ownership. */
 do_input_boost(&work);
 do_input_boost_rem(&work);
 assert(refs[1]==1 && refs[2]==1);
 sched_boost_on_input=UINT_MAX; /* Must not become a signed disable request. */
 do_input_boost(&work);
 assert(refs[1]==1 && refs[2]==1);
 do_input_boost_rem(&work);
 assert(refs[1]==1 && refs[2]==1);
 puts("PASS: boost refresh, expiry and invalid settings preserve other clients");
}
'''
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)
    (path/'test.c').write_text(code+active+'\n'+workers+main)
    subprocess.run(['cc','-Wall','-Wextra','-Werror','-Wno-unused-parameter',
                    '-fsanitize=address,undefined',str(path/'test.c'),
                    '-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
