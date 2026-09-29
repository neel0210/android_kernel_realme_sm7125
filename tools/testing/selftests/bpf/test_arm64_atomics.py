#!/usr/bin/env python3
"""Host-check the actual ARM64 LL/SC emitter, including a failed STXR retry."""
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[4]
source = (ROOT / 'arch/arm64/net/bpf_jit_comp.c').read_text()
start = source.index('static int emit_ll_sc_atomic(')
end = source.index('\nbool bpf_jit_supports_atomics', start)
emitter = source[start:end]
registers = source[source.index('static const int bpf2a64'):source.index('struct jit_ctx')]
# Use the tree's opcode definitions, not a second copy of the atomic ABI.
defines = '\n'.join(line for f in ['include/uapi/linux/bpf.h', 'include/uapi/linux/bpf_common.h']
                    for line in (ROOT / f).read_text().splitlines()
                    if re.match(r'#define\s+BPF_(?:CLASS|SIZE|STX|W|DW|ADD|AND|OR|XOR|FETCH|ATOMIC|XCHG|CMPXCHG)\b', line))
prelude = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
typedef uint8_t u8;
typedef int16_t s16;
typedef int32_t s32;
#define A64_R(n) (n)
enum { BPF_REG_0, BPF_REG_1, BPF_REG_2, BPF_REG_3, BPF_REG_4,
 BPF_REG_5, BPF_REG_6, BPF_REG_7, BPF_REG_8, BPF_REG_9, BPF_REG_FP, BPF_REG_AX,
 TMP_REG_1, TMP_REG_2, TMP_REG_3, TCALL_CNT };
struct bpf_insn { u8 code, dst_reg, src_reg; s16 off; s32 imm; };
struct prog { struct bpf_insn *insnsi; };
enum { MOV, MOVI, LOAD, ADD, AND, OR, XOR, STORE, RELEASE, CBNZ, DMB };
struct op { int code, wide, d, a, b, imm; };
struct jit_ctx { struct prog *prog; struct op ops[32]; int idx; };
#define OP(c,w,d,a,b,n) ((struct op){c,w,d,a,b,n})
#define A64_MOV(w,d,a) OP(MOV,w,d,a,0,0)
#define A64_LDXR(w,d,a) OP(LOAD,w,d,a,0,0)
#define A64_ADD(w,d,a,b) OP(ADD,w,d,a,b,0)
#define A64_AND(w,d,a,b) OP(AND,w,d,a,b,0)
#define A64_ORR(w,d,a,b) OP(OR,w,d,a,b,0)
#define A64_EOR(w,d,a,b) OP(XOR,w,d,a,b,0)
#define A64_STXR(w,d,a,b) OP(STORE,w,d,a,b,0)
#define A64_STLXR(w,d,a,b) OP(RELEASE,w,d,a,b,0)
#define A64_CBNZ(w,d,n) OP(CBNZ,w,d,0,0,n)
#define A64_DMB_ISH OP(DMB,0,0,0,0,0)
#define check_imm19(n) do { assert((n) > -262144 && (n) < 262144); (void)i; } while (0)
#define pr_err_once(...) do {} while (0)
static void emit(struct op op, struct jit_ctx *ctx) { assert(ctx->idx<32); ctx->ops[ctx->idx++]=op; }
static void emit_a64_mov_i(int w,int d,int imm,struct jit_ctx *ctx) { emit(OP(MOVI,w,d,0,0,imm),ctx); }
'''
main = r'''
static void execute(struct jit_ctx *c, uint64_t *r, uint64_t *mem, int retry) {
 int pc=0, steps=0;
 while(pc<c->idx) {
  assert(++steps<100);
  struct op o=c->ops[pc]; uint64_t v=0, mask=o.wide ? UINT64_MAX : UINT32_MAX;
  switch(o.code) {
   case MOV: v=r[o.a]; break;
   case MOVI: v=(int64_t)o.imm; break;
   case LOAD: assert(r[o.a]==0x1000); v=*mem; break;
   case ADD: v=r[o.a]+r[o.b]; break;
   case AND: v=r[o.a]&r[o.b]; break;
   case OR: v=r[o.a]|r[o.b]; break;
   case XOR: v=r[o.a]^r[o.b]; break;
   case STORE: case RELEASE:
    assert(r[o.a]==0x1000);
    r[o.b]=retry ? 1 : 0;
    if (retry) retry=0; else *mem=(*mem & ~mask) | (r[o.d]&mask);
    pc++; continue;
   case CBNZ: pc += (r[o.d]&mask) ? o.imm : 1; continue;
   case DMB: pc++; continue;
   default: assert(0);
  }
  r[o.d]=v&mask; pc++;
 }
}
int main(void) {
 int ops[]={BPF_ADD,BPF_AND,BPF_OR,BPF_XOR,BPF_ADD|BPF_FETCH,
 BPF_AND|BPF_FETCH,BPF_OR|BPF_FETCH,BPF_XOR|BPF_FETCH,BPF_XCHG,BPF_CMPXCHG};
 unsigned count=0;
 for(int wide=0;wide<2;wide++) for(int k=0;k<10;k++)
 for(int retry=0;retry<2;retry++) for(int offset=-8;offset<=8;offset+=8)
 for(int fail=0;fail<2;fail++) {
  struct bpf_insn in={BPF_STX|BPF_ATOMIC|(wide?BPF_DW:BPF_W),BPF_REG_2,BPF_REG_1,offset,ops[k]};
  struct prog p={&in}; struct jit_ctx c={.prog=&p};
  assert(emit_ll_sc_atomic(&in,&c)==0);
  uint64_t old=0x10000002aULL, val=0x200000013ULL, mem=old, r[32]={0};
  uint64_t mask=wide?UINT64_MAX:UINT32_MAX, a=old&mask, b=val&mask, expected=a;
  r[bpf2a64[BPF_REG_2]]=0x1000-offset;
  r[bpf2a64[BPF_REG_1]]=val;
  r[bpf2a64[BPF_REG_0]]=fail ? 77 : a;
  switch(ops[k]) {
   case BPF_ADD: case BPF_ADD|BPF_FETCH: expected=a+b; break;
   case BPF_AND: case BPF_AND|BPF_FETCH: expected=a&b; break;
   case BPF_OR: case BPF_OR|BPF_FETCH: expected=a|b; break;
   case BPF_XOR: case BPF_XOR|BPF_FETCH: expected=a^b; break;
   case BPF_XCHG: expected=b; break;
   case BPF_CMPXCHG: expected=fail?a:b; break;
  }
  execute(&c,r,&mem,retry);
  assert(mem==((old&~mask)|(expected&mask)));
  assert(r[bpf2a64[BPF_REG_1]]==((ops[k]&BPF_FETCH)&&ops[k]!=BPF_CMPXCHG?a:val));
  if(ops[k]==BPF_CMPXCHG) assert(r[bpf2a64[BPF_REG_0]]==a);
  count++;
 }
 printf("PASS: %u ARM64 emitter cases (32/64-bit, offsets, retries, cmpxchg match/mismatch)\n",count);
}
'''
with tempfile.TemporaryDirectory() as temp:
    c = pathlib.Path(temp) / 'check.c'
    c.write_text(prelude + defines + '\n' + registers + emitter + main)
    exe = pathlib.Path(temp) / 'check'
    subprocess.run(['clang', '-std=c11', '-Wall', '-Werror', '-fsanitize=address,undefined', str(c), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
