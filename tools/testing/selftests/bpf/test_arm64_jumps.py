#!/usr/bin/env python3
"""Exercise the real conditional-jump emitter with modeled ARM64 CMP/TST flags.

Checks width, signedness and branch selection, not machine-code execution.
"""
import ctypes
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[4]
source = (ROOT / 'arch/arm64/net/bpf_jit_comp.c').read_text()
body = source[source.index('\t/* IF (dst COND src)'):source.index('\t/* function call */')]
width = re.search(r'const bool is64 = .*?;', source, re.S).group()
defines = '\n'.join(line for name in ('bpf.h', 'bpf_common.h')
                    for line in (ROOT / 'include/uapi/linux' / name).read_text().splitlines()
                    if re.match(r'#define\s+BPF_(?:CLASS|OP|ALU64|JMP32|JMP|J\w+|X|K)\b', line))
prelude = r'''
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>
#include <errno.h>
enum { A64_COND_EQ, A64_COND_NE, A64_COND_HI, A64_COND_CC,
 A64_COND_CS, A64_COND_LS, A64_COND_GT, A64_COND_LT, A64_COND_GE, A64_COND_LE };
struct jit_ctx { uint64_t r[3]; bool z,n,c,v; int taken, offset; };
static int cmp(struct jit_ctx *ctx, bool wide, int a, int b, bool test) {
 uint64_t mask=wide?UINT64_MAX:UINT32_MAX, sign=wide?1ULL<<63:1ULL<<31;
 uint64_t x=ctx->r[a]&mask, y=ctx->r[b]&mask, r=(test?x&y:x-y)&mask;
 ctx->z=!r; ctx->n=!!(r&sign); ctx->c=!test && x>=y;
 ctx->v=!test && !!((x^y)&(x^r)&sign); return 0;
}
static int branch(struct jit_ctx *ctx, int cond, int offset) {
 bool z=ctx->z,n=ctx->n,c=ctx->c,v=ctx->v;
 bool flags[]={z,!z,c&&!z,!c,c,!c||z,!z&&(n==v),n!=v,n==v,z||(n!=v)};
 ctx->taken=flags[cond]; ctx->offset=offset; return 0;
}
#define A64_CMP(w,a,b) cmp(ctx,w,a,b,false)
#define A64_TST(w,a,b) cmp(ctx,w,a,b,true)
#define A64_B_(c,o) branch(ctx,c,o)
#define emit(op,ctx) ((void)(op))
#define check_imm19(o) assert((o)>=-262144 && (o)<262144)
static int bpf2a64_offset(int target,int i,struct jit_ctx *ctx) {
 (void)ctx; return target-i;
}
static void emit_a64_mov_i(bool wide,int reg,int32_t imm,struct jit_ctx *ctx) {
 ctx->r[reg]=wide?(uint64_t)(int64_t)imm:(uint32_t)imm;
}
int run(int code,uint64_t a,uint64_t b,int32_t imm,int off) {
 struct jit_ctx state={.r={a,b,0},.taken=-1}, *ctx=&state;
 int dst=0,src=1,tmp=2,i=0,jmp_offset,jmp_cond;
'''
ops = {0x10: lambda a,b:a==b, 0x20:lambda a,b:a>b,
       0x30:lambda a,b:a>=b, 0x40:lambda a,b:bool(a&b),
       0x50:lambda a,b:a!=b, 0x60:lambda a,b:a>b,
       0x70:lambda a,b:a>=b, 0xa0:lambda a,b:a<b,
       0xb0:lambda a,b:a<=b, 0xc0:lambda a,b:a<b,
       0xd0:lambda a,b:a<=b}
values = (0, 1, 0x7fffffff, 0x80000000, 0xffffffff,
          0x100000000, 0x100000001, 0x8000000080000000, 0xffffffffffffffff)
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)
    (path/'test.c').write_text(defines+'\n'+prelude+width+'\n(void)is64; switch(code) {\n'+body+
                             '\ndefault: return -1; } return ctx->taken ? ctx->offset : 0; }\n')
    subprocess.run(['cc','-shared','-fPIC','-Wall','-Wextra','-Werror',
                    str(path/'test.c'),'-o',str(path/'test.so')],check=True)
    run = ctypes.CDLL(str(path/'test.so')).run
    run.argtypes = [ctypes.c_int,ctypes.c_uint64,ctypes.c_uint64,
                   ctypes.c_int32,ctypes.c_int]
    count = 0
    for bits in (32,64):
        for reg in (False,True):
            for op, compare in ops.items():
                for a in values:
                    for b in values:
                        x = a & ((1<<bits)-1)
                        y = b if reg else ctypes.c_int32(b).value
                        y &= (1<<bits)-1
                        if op in (0x60,0x70,0xc0,0xd0):
                            x = x-(1<<bits) if x>>(bits-1) else x
                            y = y-(1<<bits) if y>>(bits-1) else y
                        for offset in (-19,23):
                            code = (6 if bits==32 else 5)|op|(8 if reg else 0)
                            got = run(code,a,b,ctypes.c_int32(b).value,offset)
                            want = offset if compare(x,y) else 0
                            assert got==want, (hex(code),hex(a),hex(b),got,want)
                            count += 1
    print(f'PASS: {count} conditional-jump emitter cases')
