//======================================================================
// museed-arm64.S -- ALM v0.1 kernel in ARM64 assembly (mu-Seed-ASM).
//
// Same kappa as kernels/museed.py, kernels/museed.sh and kernels/museed.sql,
// on the other end of the abstraction range: no allocator, no string library,
// no JSON parser, five syscalls (read, write, open, close, exit).
//
// It fits in assembly for one reason, and the reason is the specification
// rather than the instruction set: ALM keeps the kernel payload-blind
// (ALM v0.1 s2.1). Everything this file decides is a comparison between small
// integers and short tokens. Prompt bytes and tool output never arrive here.
//
//   stdin  events    stdout effects    fd 3 / $ALM_TRACE  canonical trace
//   exit 0 after final, 3 on EOF before terminal
//
// NOTE: the extension must stay capital-S (the C preprocessor runs on it), and
// on a case-insensitive filesystem there must never be a museed-arm64.s beside
// it -- they are the same file, and deleting one deletes both.
//======================================================================

//======================================================================
// One source, two operating systems.
//
// Everything past this block is the same instruction stream on Darwin and
// Linux. What differs is syscall numbering, the syscall register, how a
// symbol's address is spelled, what the sections are called, and the flag bits
// for creating a file. Those five things live here and nowhere else.
//
//   macOS/arm64 : clang -arch arm64 -o museed-arm64 museed-arm64.S
//   Linux/arm64 : cc -o museed-arm64 museed-arm64.S
//======================================================================
#if defined(__APPLE__)
# define SYS_READ    3
# define SYS_WRITE   4
# define SYS_OPEN    5
# define SYS_EXIT    1
# define SVC_IMM     0x80
# define SYSREG      x16
# define O_WCT       1537              // 0x001 | 0x200 | 0x400
# define MAIN_SYM    _main
# define RODATA_SECTION .section __TEXT,__const
# define DATA_SECTION   .section __DATA,__data
# define BSS_SECTION    .section __DATA,__bss
# define TEXT_SECTION   .section __TEXT,__text
#else
# define SYS_READ    63
# define SYS_WRITE   64
# define SYS_OPENAT  56
# define SYS_EXIT    94                // exit_group
# define SVC_IMM     0
# define SYSREG      x8
# define O_WCT       577               // 01 | 0100 | 01000
# define MAIN_SYM    main
# define RODATA_SECTION .section .rodata
# define DATA_SECTION   .data
# define BSS_SECTION    .bss
# define TEXT_SECTION   .text
#endif

        .macro ADRP_HI reg, sym
#if defined(__APPLE__)
        adrp    \reg, \sym@PAGE
#else
        adrp    \reg, \sym
#endif
        .endm
        .macro ADD_LO dst, base, sym
#if defined(__APPLE__)
        add     \dst, \base, \sym@PAGEOFF
#else
        add     \dst, \base, :lo12:\sym
#endif
        .endm
        .macro LDR_LO dst, base, sym
#if defined(__APPLE__)
        ldr     \dst, [\base, \sym@PAGEOFF]
#else
        ldr     \dst, [\base, :lo12:\sym]
#endif
        .endm
        .macro STR_LO src, base, sym
#if defined(__APPLE__)
        str     \src, [\base, \sym@PAGEOFF]
#else
        str     \src, [\base, :lo12:\sym]
#endif
        .endm

        RODATA_SECTION
        .p2align 3

// ---- phase names -----------------------------------------------------
ph_init:        .asciz "init"
ph_await_model: .asciz "await_model"
ph_await_tool:  .asciz "await_tool"
ph_terminal:    .asciz "terminal"

// ---- ABI key needles -------------------------------------------------
k_t:            .asciz "\"t\":"
k_eid:          .asciz "\"eid\":"
k_status:       .asciz "\"status\":"
k_action:       .asciz "\"action\":"
k_tool:         .asciz "\"tool\":"
k_halt:         .asciz "\"halt\":"
k_arg:          .asciz "\"arg_ref\":"
k_obs:          .asciz "\"obs_ref\":"

// ---- tokens ----------------------------------------------------------
t_model_resp:   .asciz "model_response"
t_tool_resp:    .asciz "tool_response"
s_ok:           .asciz "ok"
s_invalid:      .asciz "invalid"
s_transport:    .asciz "transport_error"
s_error:        .asciz "error"
s_timeout:      .asciz "timeout"
a_tool:         .asciz "tool"
a_halt:         .asciz "halt"
s_dash:         .asciz "-"
s_start:        .asciz "start"
s_stale:        .asciz "stale_event"
s_after:        .asciz "after_terminal"
s_unknown:      .asciz "unknown"
s_qmark:        .asciz "?"
s_r0:           .asciz "r0"
s_o0:           .asciz "o0"

// ---- environment names ----------------------------------------------
e_run:          .asciz "ALM_RUN="
e_steps:        .asciz "ALM_STEPS="
e_repairs:      .asciz "ALM_REPAIRS="
e_retries:      .asciz "ALM_RETRIES="
e_hmax:         .asciz "ALM_HISTORY_MAX="
e_feedback:     .asciz "ALM_FEEDBACK="
e_allowhalt:    .asciz "ALM_ALLOW_HALT="
e_trace:        .asciz "ALM_TRACE="
d_run:          .asciz "r1"

// ---- effect fragments ------------------------------------------------
f_mr1:          .asciz "{\"v\":1,\"t\":\"model_request\",\"run\":\""
f_mr2:          .asciz "\",\"step\":"
f_mr3:          .asciz ",\"eid\":\"e"
f_mr4:          .asciz "\",\"attempt\":"
f_mr5:          .asciz ",\"refs\":\""
f_mr6:          .asciz "\",\"steps_left\":"
f_mr7:          .asciz "}"

f_tr1:          .asciz "{\"v\":1,\"t\":\"tool_request\",\"run\":\""
f_tr4:          .asciz "\",\"tool\":\""
f_tr5:          .asciz "\",\"arg_ref\":\""
f_tr6:          .asciz "\"}"

f_fi1:          .asciz "{\"v\":1,\"t\":\"final\",\"run\":\""
f_fi3:          .asciz ",\"outcome\":\""
f_fi4:          .asciz "\",\"status\":\""
f_fi5:          .asciz "\",\"reason\":\""
f_fi6:          .asciz "\",\"steps_used\":"

o_halted:       .asciz "halted"
o_aborted:      .asciz "aborted"
r_model_halt:   .asciz "model_halt"
r_budget:       .asciz "budget_exhausted"
r_protocol:     .asciz "protocol_exhausted"
r_transport:    .asciz "transport_exhausted"
s_pipe:         .asciz "|"
s_nl:           .asciz "\n"

//======================================================================
        DATA_SECTION
        .p2align 3
st_phase:       .quad 0          // 0 init 1 await_model 2 await_tool 3 terminal
st_step:        .quad 1
st_attempt:     .quad 1
st_eidn:        .quad 0
st_steps:       .quad 16
st_repairs:     .quad 2
st_retries:     .quad 3
st_hmax:        .quad -1
st_feedback:    .quad 1
st_allowhalt:   .quad 1
st_used:        .quad 0
pre_step:       .quad 1
pre_phase:      .quad 0
trace_fd:       .quad 3
hist_n:         .quad 0
in_len:         .quad 0
in_pos:         .quad 0
envp:           .quad 0
run_ptr:        .quad 0
run_len:        .quad 2
optr:           .quad 0
refs_len:       .quad 0
// current event slices (ptr,len)
ev_t_p:         .quad 0
ev_t_l:         .quad 0
ev_eid_p:       .quad 0
ev_eid_l:       .quad 0
ev_st_p:        .quad 0
ev_st_l:        .quad 0
ev_ac_p:        .quad 0
ev_ac_l:        .quad 0
ev_to_p:        .quad 0
ev_to_l:        .quad 0
ev_ha_p:        .quad 0
ev_ha_l:        .quad 0
ev_ar_p:        .quad 0
ev_ar_l:        .quad 0
ev_ob_p:        .quad 0
ev_ob_l:        .quad 0
// trace record fields
tr_ev_p:        .quad 0
tr_ev_l:        .quad 0
tr_st_p:        .quad 0
tr_st_l:        .quad 0
tr_ac_p:        .quad 0
tr_ac_l:        .quad 0
tr_rf_p:        .quad 0
tr_rf_l:        .quad 0
tr_fl_p:        .quad 0
tr_fl_l:        .quad 0

        BSS_SECTION
        .p2align 4
obuf:           .space 16384      // output string builder
linebuf:        .space 65536      // one input line
inbuf:          .space 262144     // stdin read buffer
refsbuf:        .space 65536      // rendered ref list
histbuf:        .space 131072     // 4096 slots x 32 bytes: [len][bytes]

        TEXT_SECTION
        .p2align 2
        .globl MAIN_SYM

//---------------------------------------------------------------- syscalls
// x0..x2 args, returns x0. The only place the two operating systems differ in
// behaviour rather than in spelling: Linux returns -errno in x0, Darwin sets
// the carry flag. Every check below is a sign test or a "< 1" test, so both
// are handled by the same instructions.
sys_read:
        mov     SYSREG, #SYS_READ
        svc     #SVC_IMM
        ret
sys_write:
        mov     SYSREG, #SYS_WRITE
        svc     #SVC_IMM
        ret
sys_open:                                // x0 path, x1 flags, x2 mode
#if defined(__APPLE__)
        mov     SYSREG, #SYS_OPEN
        svc     #SVC_IMM
#else
        mov     x3, x2                   // Linux has no open(2): openat(AT_FDCWD, ...)
        mov     x2, x1
        mov     x1, x0
        mov     x0, #-100
        mov     SYSREG, #SYS_OPENAT
        svc     #SVC_IMM
#endif
        ret
sys_exit:
        mov     SYSREG, #SYS_EXIT
        svc     #SVC_IMM
        ret

//---------------------------------------------------------------- strlen
// x0 = ptr -> x0 = len
strlen:
        mov     x1, x0
1:      ldrb    w2, [x0]
        cbz     w2, 2f
        add     x0, x0, #1
        b       1b
2:      sub     x0, x0, x1
        ret

//---------------------------------------------------------- string builder
sb_reset:
        ADRP_HI x0, obuf
        ADD_LO  x0, x0, obuf
        ADRP_HI x1, optr
        STR_LO  x0, x1, optr
        ret

// x0 = ptr, x1 = len
sb_bytes:
        ADRP_HI x3, optr
        LDR_LO  x2, x3, optr
        cbz     x1, 2f
1:      ldrb    w4, [x0], #1
        strb    w4, [x2], #1
        subs    x1, x1, #1
        b.ne    1b
2:      STR_LO  x2, x3, optr
        ret

// x0 = NUL terminated literal
sb_lit:
        stp     x29, x30, [sp, #-16]!
        mov     x9, x0
        bl      strlen
        mov     x1, x0
        mov     x0, x9
        bl      sb_bytes
        ldp     x29, x30, [sp], #16
        ret

// x0 = signed value
sb_int:
        stp     x29, x30, [sp, #-32]!
        stp     x19, x20, [sp, #16]
        sub     sp, sp, #32
        mov     x19, x0
        tbz     x19, #63, 1f
        neg     x19, x19
        mov     w3, #45                  // '-'
        add     x0, sp, #0
        strb    w3, [x0]
        mov     x1, #1
        bl      sb_bytes
1:      add     x4, sp, #31              // write digits backwards
        mov     x20, #0
        mov     x6, #10
2:      udiv    x7, x19, x6
        msub    x8, x7, x6, x19          // x8 = x19 % 10
        add     w8, w8, #48
        strb    w8, [x4], #-1
        add     x20, x20, #1
        mov     x19, x7
        cbnz    x19, 2b
        add     x0, x4, #1
        mov     x1, x20
        bl      sb_bytes
        add     sp, sp, #32
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// flush builder to fd x0
sb_flush:
        stp     x29, x30, [sp, #-16]!
        mov     x9, x0
        ADRP_HI x1, obuf
        ADD_LO  x1, x1, obuf
        ADRP_HI x3, optr
        LDR_LO  x2, x3, optr
        sub     x2, x2, x1
        mov     x0, x9
        bl      sys_write
        ldp     x29, x30, [sp], #16
        ret

//------------------------------------------------------------ comparisons
// x0=ptr x1=len x2=NUL literal -> x0 = 1 if equal
streq_lit:
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        mov     x20, x1
        mov     x0, x2
        mov     x21, x2
        bl      strlen
        cmp     x0, x20
        b.ne    3f
        mov     x3, #0
1:      cmp     x3, x20
        b.eq    2f
        ldrb    w4, [x19, x3]
        ldrb    w5, [x21, x3]
        cmp     w4, w5
        b.ne    3f
        add     x3, x3, #1
        b       1b
2:      mov     x0, #1
        b       4f
3:      mov     x0, #0
4:      ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

//--------------------------------------------------------------- find_key
// x0 = line ptr, x1 = line len, x2 = needle literal ("key":)
// -> x0 = value ptr (0 if absent), x1 = value len
find_key:
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0                  // line
        mov     x20, x1                  // line len
        mov     x21, x2                  // needle
        mov     x0, x2
        bl      strlen
        mov     x22, x0                  // needle len
        mov     x3, #0                   // i
1:      add     x4, x3, x22
        cmp     x4, x20
        b.gt    9f
        mov     x5, #0
2:      cmp     x5, x22
        b.eq    3f
        add     x6, x19, x3
        ldrb    w7, [x6, x5]
        ldrb    w8, [x21, x5]
        cmp     w7, w8
        b.ne    4f
        add     x5, x5, #1
        b       2b
4:      add     x3, x3, #1
        b       1b
3:      // matched at i; value starts at i+needle_len
        add     x0, x19, x4              // value start
        add     x5, x19, x20             // line end
        ldrb    w6, [x0]
        cmp     w6, #34                  // '"'
        b.ne    6f
        add     x0, x0, #1
        mov     x1, #0
5:      add     x7, x0, x1
        cmp     x7, x5
        b.ge    8f
        ldrb    w6, [x7]
        cmp     w6, #34
        b.eq    8f
        add     x1, x1, #1
        b       5b
6:      mov     x1, #0
7:      add     x7, x0, x1
        cmp     x7, x5
        b.ge    8f
        ldrb    w6, [x7]
        cmp     w6, #44                  // ','
        b.eq    8f
        cmp     w6, #125                 // '}'
        b.eq    8f
        add     x1, x1, #1
        b       7b
8:      b       10f
9:      mov     x0, #0
        mov     x1, #0
10:     ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

//------------------------------------------------------------------ env
// x0 = "NAME=" literal -> x0 = value ptr or 0
env_find:
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x21, x0
        bl      strlen
        mov     x22, x0                  // name len
        ADRP_HI x0, envp
        LDR_LO  x19, x0, envp
1:      ldr     x20, [x19], #8
        cbz     x20, 9f
        mov     x3, #0
2:      cmp     x3, x22
        b.eq    3f
        ldrb    w4, [x20, x3]
        ldrb    w5, [x21, x3]
        cmp     w4, w5
        b.ne    1b
        add     x3, x3, #1
        b       2b
3:      add     x0, x20, x22
        b       10f
9:      mov     x0, #0
10:     ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

// x0 = ptr -> x0 = int
atoi:
        mov     x1, #0
        mov     x2, #0                   // sign
        ldrb    w3, [x0]
        cmp     w3, #45
        b.ne    1f
        mov     x2, #1
        add     x0, x0, #1
1:      ldrb    w3, [x0], #1
        sub     w4, w3, #48
        cmp     w4, #9
        b.hi    2f
        mov     x5, #10
        mul     x1, x1, x5
        add     x1, x1, x4
        b       1b
2:      cbz     x2, 3f
        neg     x1, x1
3:      mov     x0, x1
        ret

// x0 = "NAME=" literal, x1 = default -> x0 = value
env_int:
        stp     x29, x30, [sp, #-32]!
        stp     x19, x20, [sp, #16]
        mov     x19, x1
        bl      env_find
        cbz     x0, 1f
        ldrb    w1, [x0]
        cbz     w1, 1f
        bl      atoi
        b       2f
1:      mov     x0, x19
2:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

//------------------------------------------------------------------ hist
// x0 = ref ptr, x1 = ref len. H is a 4096-entry ring: exact for any
// history_max <= 4096, lossy only for an unbounded H longer than that.
hist_append:
        ADRP_HI x2, hist_n
        LDR_LO  x3, x2, hist_n
        ADRP_HI x5, histbuf
        ADD_LO  x5, x5, histbuf
        and     x6, x3, #4095            // ring of 4096 slots
        lsl     x6, x6, #5               // *32
        add     x5, x5, x6
        mov     x7, #31
        cmp     x1, x7
        csel    x1, x1, x7, lo
        strb    w1, [x5]
        add     x5, x5, #1
        mov     x6, #0
1:      cmp     x6, x1
        b.eq    2f
        ldrb    w7, [x0, x6]
        strb    w7, [x5, x6]
        add     x6, x6, #1
        b       1b
2:      add     x3, x3, #1
        STR_LO  x3, x2, hist_n
        ret

// render the ref list the next model_request carries into refsbuf
build_refs:
        stp     x29, x30, [sp, #-64]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        ADRP_HI x0, hist_n
        LDR_LO  x19, x0, hist_n          // n
        ADRP_HI x0, st_hmax
        LDR_LO  x20, x0, st_hmax
        mov     x21, #0                          // start
        tbnz    x20, #63, 1f                     // hmax < 0 -> start 0
        subs    x21, x19, x20
        b.pl    1f
        mov     x21, #0
1:      // the ring holds at most 4096 entries; an unbounded H older than that
        // is not recoverable, which is this kernel's one stated H limit
        sub     x0, x19, x21
        mov     x1, #4096
        cmp     x0, x1
        b.le    11f
        sub     x21, x19, x1
11:     ADRP_HI x22, refsbuf
        ADD_LO  x22, x22, refsbuf
        cmp     x21, x19
        b.lt    2f
        mov     w0, #45                          // '-'
        strb    w0, [x22]
        mov     x0, #1
        b       6f
2:      mov     x23, x21
        mov     x24, x22
3:      cmp     x23, x19
        b.ge    5f
        cmp     x23, x21
        b.eq    4f
        mov     w0, #44                          // ','
        strb    w0, [x24], #1
4:      ADRP_HI x0, histbuf
        ADD_LO  x0, x0, histbuf
        and     x1, x23, #4095
        lsl     x1, x1, #5
        add     x0, x0, x1
        ldrb    w1, [x0], #1
        mov     x2, #0
41:     cmp     x2, x1
        b.eq    42f
        ldrb    w3, [x0, x2]
        strb    w3, [x24], #1
        add     x2, x2, #1
        b       41b
42:     add     x23, x23, #1
        b       3b
5:      sub     x0, x24, x22
6:      ADRP_HI x1, refs_len
        STR_LO  x0, x1, refs_len
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

//--------------------------------------------------------------- readline
// -> x0 = ptr to line (in linebuf), x1 = len, or x0 = 0 at EOF
readline:
        stp     x29, x30, [sp, #-64]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        ADRP_HI x19, inbuf
        ADD_LO  x19, x19, inbuf
        ADRP_HI x20, in_pos
        ADRP_HI x21, in_len
1:      LDR_LO  x22, x20, in_pos
        LDR_LO  x23, x21, in_len
        mov     x24, x22
2:      cmp     x24, x23
        b.ge    4f
        ldrb    w0, [x19, x24]
        cmp     w0, #10
        b.eq    3f
        add     x24, x24, #1
        b       2b
3:      // line is [x22, x24)
        ADRP_HI x0, linebuf
        ADD_LO  x0, x0, linebuf
        sub     x1, x24, x22
        add     x2, x19, x22
        mov     x3, #0
31:     cmp     x3, x1
        b.eq    32f
        ldrb    w4, [x2, x3]
        strb    w4, [x0, x3]
        add     x3, x3, #1
        b       31b
32:     add     x24, x24, #1
        STR_LO  x24, x20, in_pos
        b       9f
4:      // compact and refill
        sub     x2, x23, x22
        mov     x3, #0
41:     cmp     x3, x2
        b.eq    42f
        add     x4, x19, x22
        ldrb    w5, [x4, x3]
        strb    w5, [x19, x3]
        add     x3, x3, #1
        b       41b
42:     mov     x0, #0
        STR_LO  x0, x20, in_pos
        STR_LO  x2, x21, in_len
        mov     x0, #0                    // fd 0
        add     x1, x19, x2
        mov     x3, #262144
        sub     x2, x3, x2
        bl      sys_read
        cmp     x0, #1
        b.lt    5f
        LDR_LO  x2, x21, in_len
        add     x2, x2, x0
        STR_LO  x2, x21, in_len
        b       1b
5:      // EOF: return trailing partial line if any
        LDR_LO  x23, x21, in_len
        LDR_LO  x22, x20, in_pos
        cmp     x23, x22
        b.le    8f
        ADRP_HI x0, linebuf
        ADD_LO  x0, x0, linebuf
        sub     x1, x23, x22
        mov     x3, #0
51:     cmp     x3, x1
        b.eq    52f
        add     x4, x19, x22
        ldrb    w5, [x4, x3]
        strb    w5, [x0, x3]
        add     x3, x3, #1
        b       51b
52:     STR_LO  x23, x20, in_pos
        b       9f
8:      mov     x0, #0
        mov     x1, #0
9:      ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

//----------------------------------------------------------------- emit
// phase name for value in x0 -> x0 = literal ptr
phase_name:
        cmp     x0, #0
        b.ne    1f
        ADRP_HI x0, ph_init
        ADD_LO  x0, x0, ph_init
        ret
1:      cmp     x0, #1
        b.ne    2f
        ADRP_HI x0, ph_await_model
        ADD_LO  x0, x0, ph_await_model
        ret
2:      cmp     x0, #2
        b.ne    3f
        ADRP_HI x0, ph_await_tool
        ADD_LO  x0, x0, ph_await_tool
        ret
3:      ADRP_HI x0, ph_terminal
        ADD_LO  x0, x0, ph_terminal
        ret

.macro LOADQ reg, sym
        ADRP_HI \reg, \sym
        LDR_LO  \reg, \reg, \sym
.endm
.macro STOREQ reg, sym, tmp
        ADRP_HI \tmp, \sym
        STR_LO  \reg, \tmp, \sym
.endm
.macro LIT reg, sym
        ADRP_HI \reg, \sym
        ADD_LO  \reg, \reg, \sym
.endm

// mint the next eid: st_eidn += 1
next_eid:
        ADRP_HI x1, st_eidn
        LDR_LO  x0, x1, st_eidn
        add     x0, x0, #1
        STR_LO  x0, x1, st_eidn
        ret

emit_model_request:
        stp     x29, x30, [sp, #-16]!
        bl      build_refs
        bl      next_eid
        bl      sb_reset
        LIT     x0, f_mr1
        bl      sb_lit
        LOADQ   x0, run_ptr
        LOADQ   x1, run_len
        bl      sb_bytes
        LIT     x0, f_mr2
        bl      sb_lit
        LOADQ   x0, st_step
        bl      sb_int
        LIT     x0, f_mr3
        bl      sb_lit
        LOADQ   x0, st_eidn
        bl      sb_int
        LIT     x0, f_mr4
        bl      sb_lit
        LOADQ   x0, st_attempt
        bl      sb_int
        LIT     x0, f_mr5
        bl      sb_lit
        LIT     x0, refsbuf
        LOADQ   x1, refs_len
        bl      sb_bytes
        LIT     x0, f_mr6
        bl      sb_lit
        LOADQ   x0, st_steps
        bl      sb_int
        LIT     x0, f_mr7
        bl      sb_lit
        LIT     x0, s_nl
        bl      sb_lit
        mov     x0, #1
        bl      sb_flush
        // the trace record shows the refs this request carried
        LIT     x0, refsbuf
        STOREQ  x0, tr_rf_p, x1
        LOADQ   x0, refs_len
        STOREQ  x0, tr_rf_l, x1
        ldp     x29, x30, [sp], #16
        ret

emit_tool_request:
        stp     x29, x30, [sp, #-16]!
        bl      next_eid
        bl      sb_reset
        LIT     x0, f_tr1
        bl      sb_lit
        LOADQ   x0, run_ptr
        LOADQ   x1, run_len
        bl      sb_bytes
        LIT     x0, f_mr2
        bl      sb_lit
        LOADQ   x0, st_step
        bl      sb_int
        LIT     x0, f_mr3
        bl      sb_lit
        LOADQ   x0, st_eidn
        bl      sb_int
        LIT     x0, f_tr4
        bl      sb_lit
        LOADQ   x0, ev_to_p
        LOADQ   x1, ev_to_l
        cbnz    x0, 1f
        LIT     x0, s_unknown
        mov     x1, #7
1:      bl      sb_bytes
        LIT     x0, f_tr5
        bl      sb_lit
        LOADQ   x0, ev_ar_p
        LOADQ   x1, ev_ar_l
        bl      sb_bytes
        LIT     x0, f_tr6
        bl      sb_lit
        LIT     x0, s_nl
        bl      sb_lit
        mov     x0, #1
        bl      sb_flush
        LOADQ   x0, ev_ar_p
        STOREQ  x0, tr_rf_p, x1
        LOADQ   x0, ev_ar_l
        STOREQ  x0, tr_rf_l, x1
        ldp     x29, x30, [sp], #16
        ret

// x0 = outcome literal, x1 = reason literal, x2 = status literal
emit_final:
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        mov     x0, #3
        STOREQ  x0, st_phase, x1
        bl      sb_reset
        LIT     x0, f_fi1
        bl      sb_lit
        LOADQ   x0, run_ptr
        LOADQ   x1, run_len
        bl      sb_bytes
        LIT     x0, f_mr2
        bl      sb_lit
        LOADQ   x0, st_step
        bl      sb_int
        LIT     x0, f_fi3
        bl      sb_lit
        mov     x0, x19
        bl      sb_lit
        LIT     x0, f_fi4
        bl      sb_lit
        mov     x0, x21
        bl      sb_lit
        LIT     x0, f_fi5
        bl      sb_lit
        mov     x0, x20
        bl      sb_lit
        LIT     x0, f_fi6
        bl      sb_lit
        LOADQ   x0, st_used
        bl      sb_int
        LIT     x0, f_mr7
        bl      sb_lit
        LIT     x0, s_nl
        bl      sb_lit
        mov     x0, #1
        bl      sb_flush
        LIT     x0, s_dash
        STOREQ  x0, tr_rf_p, x1
        mov     x0, #1
        STOREQ  x0, tr_rf_l, x1
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

// canonical trace record from pre_* and tr_* globals
emit_trace:
        stp     x29, x30, [sp, #-16]!
        bl      sb_reset
        LOADQ   x0, pre_step
        bl      sb_int
        LIT     x0, s_pipe
        bl      sb_lit
        LOADQ   x0, pre_phase
        bl      phase_name
        bl      sb_lit
        LIT     x0, s_pipe
        bl      sb_lit
        LOADQ   x0, tr_ev_p
        LOADQ   x1, tr_ev_l
        bl      sb_bytes
        LIT     x0, s_pipe
        bl      sb_lit
        LOADQ   x0, tr_st_p
        LOADQ   x1, tr_st_l
        bl      sb_bytes
        LIT     x0, s_pipe
        bl      sb_lit
        LOADQ   x0, tr_ac_p
        LOADQ   x1, tr_ac_l
        bl      sb_bytes
        LIT     x0, s_pipe
        bl      sb_lit
        LOADQ   x0, st_phase
        bl      phase_name
        bl      sb_lit
        LIT     x0, s_pipe
        bl      sb_lit
        LOADQ   x0, st_steps
        bl      sb_int
        LIT     x0, s_pipe
        bl      sb_lit
        LOADQ   x0, st_repairs
        bl      sb_int
        LIT     x0, s_pipe
        bl      sb_lit
        LOADQ   x0, st_retries
        bl      sb_int
        LIT     x0, s_pipe
        bl      sb_lit
        LOADQ   x0, tr_rf_p
        LOADQ   x1, tr_rf_l
        bl      sb_bytes
        LIT     x0, s_pipe
        bl      sb_lit
        LOADQ   x0, tr_fl_p
        LOADQ   x1, tr_fl_l
        bl      sb_bytes
        LIT     x0, s_nl
        bl      sb_lit
        LOADQ   x0, trace_fd
        bl      sb_flush
        ldp     x29, x30, [sp], #16
        ret

// helpers: set tr_ac / tr_fl / tr_ev / tr_st from a literal in x0
set_ac_lit:
        stp     x29, x30, [sp, #-32]!
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        bl      strlen
        mov     x1, x0
        STOREQ  x19, tr_ac_p, x2
        STOREQ  x1, tr_ac_l, x2
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret
set_fl_lit:
        stp     x29, x30, [sp, #-32]!
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        bl      strlen
        mov     x1, x0
        STOREQ  x19, tr_fl_p, x2
        STOREQ  x1, tr_fl_l, x2
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret
set_ev_lit:
        stp     x29, x30, [sp, #-32]!
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        bl      strlen
        mov     x1, x0
        STOREQ  x19, tr_ev_p, x2
        STOREQ  x1, tr_ev_l, x2
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret
set_st_lit:
        stp     x29, x30, [sp, #-32]!
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        bl      strlen
        mov     x1, x0
        STOREQ  x19, tr_st_p, x2
        STOREQ  x1, tr_st_l, x2
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

//----------------------------------------------------------------- main
MAIN_SYM:
        stp     x29, x30, [sp, #-32]!
        stp     x19, x20, [sp, #16]
        STOREQ  x2, envp, x3

        // configuration (ABI s5)
        LIT     x0, e_steps
        mov     x1, #16
        bl      env_int
        STOREQ  x0, st_steps, x1
        LIT     x0, e_repairs
        mov     x1, #2
        bl      env_int
        STOREQ  x0, st_repairs, x1
        LIT     x0, e_retries
        mov     x1, #3
        bl      env_int
        STOREQ  x0, st_retries, x1
        LIT     x0, e_hmax
        mov     x1, #-1
        bl      env_int
        STOREQ  x0, st_hmax, x1
        LIT     x0, e_feedback
        mov     x1, #1
        bl      env_int
        STOREQ  x0, st_feedback, x1
        LIT     x0, e_allowhalt
        mov     x1, #1
        bl      env_int
        STOREQ  x0, st_allowhalt, x1

        LIT     x0, e_run
        bl      env_find
        cbnz    x0, 1f
        LIT     x0, d_run
1:      mov     x19, x0
        bl      strlen
        STOREQ  x19, run_ptr, x1
        STOREQ  x0, run_len, x1

        LIT     x0, e_trace
        bl      env_find
        cbz     x0, 2f
        ldrb    w1, [x0]
        cbz     w1, 2f
        mov     x1, #O_WCT               // O_WRONLY|O_CREAT|O_TRUNC
        mov     x2, #420                 // 0644
        bl      sys_open
        tbnz    x0, #63, 2f
        STOREQ  x0, trace_fd, x1
2:
        // ---- start (ALM s4.1)
        mov     x0, #0
        STOREQ  x0, pre_phase, x1
        mov     x0, #1
        STOREQ  x0, pre_step, x1
        STOREQ  x0, st_phase, x1         // await_model
        bl      emit_model_request
        LIT     x0, s_start
        bl      set_ev_lit
        LIT     x0, s_dash
        bl      set_st_lit
        LIT     x0, s_dash
        bl      set_ac_lit
        LIT     x0, s_dash
        bl      set_fl_lit
        bl      emit_trace

// ---- event loop ------------------------------------------------------
main_loop:
        bl      readline
        cbz     x0, main_done
        mov     x19, x0                  // line ptr
        mov     x20, x1                  // line len
        cbz     x20, main_loop
        ldrb    w0, [x19]
        cmp     w0, #123                 // '{'
        b.ne    main_loop

        // parse the ABI keys we act on
        mov     x0, x19
        mov     x1, x20
        LIT     x2, k_t
        bl      find_key
        STOREQ  x0, ev_t_p, x2
        STOREQ  x1, ev_t_l, x2
        mov     x0, x19
        mov     x1, x20
        LIT     x2, k_eid
        bl      find_key
        STOREQ  x0, ev_eid_p, x2
        STOREQ  x1, ev_eid_l, x2
        mov     x0, x19
        mov     x1, x20
        LIT     x2, k_status
        bl      find_key
        STOREQ  x0, ev_st_p, x2
        STOREQ  x1, ev_st_l, x2
        mov     x0, x19
        mov     x1, x20
        LIT     x2, k_action
        bl      find_key
        STOREQ  x0, ev_ac_p, x2
        STOREQ  x1, ev_ac_l, x2
        mov     x0, x19
        mov     x1, x20
        LIT     x2, k_tool
        bl      find_key
        STOREQ  x0, ev_to_p, x2
        STOREQ  x1, ev_to_l, x2
        mov     x0, x19
        mov     x1, x20
        LIT     x2, k_halt
        bl      find_key
        STOREQ  x0, ev_ha_p, x2
        STOREQ  x1, ev_ha_l, x2
        mov     x0, x19
        mov     x1, x20
        LIT     x2, k_arg
        bl      find_key
        cbnz    x0, 3f
        LIT     x0, s_r0
        mov     x1, #2
3:      STOREQ  x0, ev_ar_p, x2
        STOREQ  x1, ev_ar_l, x2
        mov     x0, x19
        mov     x1, x20
        LIT     x2, k_obs
        bl      find_key
        cbnz    x0, 4f
        LIT     x0, s_o0
        mov     x1, #2
4:      STOREQ  x0, ev_ob_p, x2
        STOREQ  x1, ev_ob_l, x2

        // trace event/status default to the raw tokens
        LOADQ   x0, ev_t_p
        cbnz    x0, 5f
        LIT     x0, s_qmark
        mov     x1, #1
        STOREQ  x0, ev_t_p, x2
        STOREQ  x1, ev_t_l, x2
5:      LOADQ   x0, ev_st_p
        cbnz    x0, 6f
        LIT     x0, s_dash
        mov     x1, #1
        STOREQ  x0, ev_st_p, x2
        STOREQ  x1, ev_st_l, x2
6:      LOADQ   x0, ev_t_p
        STOREQ  x0, tr_ev_p, x2
        LOADQ   x0, ev_t_l
        STOREQ  x0, tr_ev_l, x2
        LOADQ   x0, ev_st_p
        STOREQ  x0, tr_st_p, x2
        LOADQ   x0, ev_st_l
        STOREQ  x0, tr_st_l, x2
        LIT     x0, s_dash
        bl      set_ac_lit
        LIT     x0, s_dash
        bl      set_fl_lit
        LIT     x0, s_dash
        STOREQ  x0, tr_rf_p, x1
        mov     x0, #1
        STOREQ  x0, tr_rf_l, x1

        // snapshot pre-transition step/phase
        LOADQ   x0, st_step
        STOREQ  x0, pre_step, x1
        LOADQ   x0, st_phase
        STOREQ  x0, pre_phase, x1

        // terminal is absorbing (ALM s4.6)
        LOADQ   x0, st_phase
        cmp     x0, #3
        b.ne    class_check
        LIT     x0, s_after
        bl      set_fl_lit
        bl      emit_trace
        b       main_loop

class_check:
        // eid must equal the outstanding effect: pending is always "e"+eidn
        LOADQ   x0, ev_eid_p
        cbz     x0, go_stale
        ldrb    w1, [x0]
        cmp     w1, #101                 // 'e'
        b.ne    go_stale
        add     x0, x0, #1
        bl      atoi
        LOADQ   x1, st_eidn
        cmp     x0, x1
        b.ne    go_stale

        LOADQ   x0, ev_t_p
        LOADQ   x1, ev_t_l
        LIT     x2, t_model_resp
        bl      streq_lit
        cbnz    x0, cls_model
        LOADQ   x0, ev_t_p
        LOADQ   x1, ev_t_l
        LIT     x2, t_tool_resp
        bl      streq_lit
        cbnz    x0, cls_tool
        b       go_stale

cls_model:
        LOADQ   x0, st_phase
        cmp     x0, #1
        b.ne    go_stale
        LOADQ   x0, ev_st_p
        LOADQ   x1, ev_st_l
        LIT     x2, s_ok
        bl      streq_lit
        cbnz    x0, cls_model_ok
        LOADQ   x0, ev_st_p
        LOADQ   x1, ev_st_l
        LIT     x2, s_invalid
        bl      streq_lit
        cbnz    x0, rule_invalid
        LOADQ   x0, ev_st_p
        LOADQ   x1, ev_st_l
        LIT     x2, s_transport
        bl      streq_lit
        cbnz    x0, rule_transport
        b       go_stale

cls_model_ok:
        LOADQ   x0, ev_ac_p
        LOADQ   x1, ev_ac_l
        LIT     x2, a_tool
        bl      streq_lit
        cbnz    x0, rule_tool
        LOADQ   x0, ev_ac_p
        LOADQ   x1, ev_ac_l
        LIT     x2, a_halt
        bl      streq_lit
        cbnz    x0, rule_halt
        b       go_stale

cls_tool:
        LOADQ   x0, st_phase
        cmp     x0, #2
        b.ne    go_stale
        LOADQ   x0, ev_st_p
        LOADQ   x1, ev_st_l
        LIT     x2, s_ok
        bl      streq_lit
        cbnz    x0, rule_obs
        LOADQ   x0, ev_st_p
        LOADQ   x1, ev_st_l
        LIT     x2, s_error
        bl      streq_lit
        cbnz    x0, rule_obs
        LOADQ   x0, ev_st_p
        LOADQ   x1, ev_st_l
        LIT     x2, s_timeout
        bl      streq_lit
        cbnz    x0, rule_obs
        b       go_stale

go_stale:
        LIT     x0, s_stale
        bl      set_fl_lit
        bl      emit_trace
        b       main_loop

// ---- s4.2 tool call --------------------------------------------------
rule_tool:
        LOADQ   x0, ev_ar_p
        LOADQ   x1, ev_ar_l
        bl      hist_append
        mov     x0, #2
        STOREQ  x0, st_phase, x1
        bl      emit_tool_request
        LIT     x0, a_tool
        bl      set_ac_lit
        bl      emit_trace
        b       main_loop

// ---- s4.3 halt -------------------------------------------------------
rule_halt:
        LOADQ   x0, st_allowhalt
        cbz     x0, rule_halt_disabled
        LOADQ   x0, ev_ar_p
        LOADQ   x1, ev_ar_l
        bl      hist_append
        LIT     x0, o_halted
        LIT     x1, r_model_halt
        LOADQ   x2, ev_ha_p
        cbnz    x2, 1f
        LIT     x2, s_ok
1:      bl      emit_final_slice
        LIT     x0, a_halt
        bl      set_ac_lit
        bl      emit_trace
        b       main_loop

rule_halt_disabled:
        LOADQ   x0, ev_ar_p
        LOADQ   x1, ev_ar_l
        bl      hist_append
        ADRP_HI x1, st_attempt
        LDR_LO  x0, x1, st_attempt
        add     x0, x0, #1
        STR_LO  x0, x1, st_attempt
        bl      emit_model_request
        LIT     x0, s_invalid
        bl      set_st_lit
        LIT     x0, a_halt
        bl      set_ac_lit
        bl      emit_trace
        b       main_loop

// ---- s4.5 protocol repair -------------------------------------------
rule_invalid:
        LOADQ   x0, st_repairs
        cmp     x0, #0
        b.le    rule_invalid_abort
        sub     x0, x0, #1
        STOREQ  x0, st_repairs, x1
        LOADQ   x0, ev_ar_p
        LOADQ   x1, ev_ar_l
        bl      hist_append
        ADRP_HI x1, st_attempt
        LDR_LO  x0, x1, st_attempt
        add     x0, x0, #1
        STR_LO  x0, x1, st_attempt
        bl      emit_model_request
        bl      emit_trace
        b       main_loop
rule_invalid_abort:
        LIT     x0, o_aborted
        LIT     x1, r_protocol
        LIT     x2, s_dash
        bl      emit_final
        bl      emit_trace
        b       main_loop

// ---- s4.5 transport retry -------------------------------------------
rule_transport:
        LOADQ   x0, st_retries
        cmp     x0, #0
        b.le    rule_transport_abort
        sub     x0, x0, #1
        STOREQ  x0, st_retries, x1
        ADRP_HI x1, st_attempt
        LDR_LO  x0, x1, st_attempt
        add     x0, x0, #1
        STR_LO  x0, x1, st_attempt
        bl      emit_model_request
        bl      emit_trace
        b       main_loop
rule_transport_abort:
        LIT     x0, o_aborted
        LIT     x1, r_transport
        LIT     x2, s_dash
        bl      emit_final
        bl      emit_trace
        b       main_loop

// ---- s4.4 observation ------------------------------------------------
rule_obs:
        LOADQ   x0, st_feedback
        cbz     x0, 1f
        LOADQ   x0, ev_ob_p
        LOADQ   x1, ev_ob_l
        bl      hist_append
1:      LOADQ   x0, st_steps
        sub     x0, x0, #1
        STOREQ  x0, st_steps, x1
        LOADQ   x1, st_used
        add     x1, x1, #1
        STOREQ  x1, st_used, x2
        cmp     x0, #0
        b.gt    2f
        LIT     x0, o_aborted
        LIT     x1, r_budget
        LIT     x2, s_dash
        bl      emit_final
        bl      emit_trace
        b       main_loop
2:      mov     x0, #1
        STOREQ  x0, st_phase, x1
        ADRP_HI x1, st_step
        LDR_LO  x0, x1, st_step
        add     x0, x0, #1
        STR_LO  x0, x1, st_step
        mov     x0, #1
        STOREQ  x0, st_attempt, x1
        bl      emit_model_request
        bl      emit_trace
        b       main_loop

main_done:
        LOADQ   x0, st_phase
        cmp     x0, #3
        b.eq    1f
        mov     x0, #3
        bl      sys_exit
1:      mov     x0, #0
        bl      sys_exit

// emit_final with a status given as a slice (the model's own halt verdict)
emit_final_slice:
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        mov     x0, #3
        STOREQ  x0, st_phase, x1
        bl      sb_reset
        LIT     x0, f_fi1
        bl      sb_lit
        LOADQ   x0, run_ptr
        LOADQ   x1, run_len
        bl      sb_bytes
        LIT     x0, f_mr2
        bl      sb_lit
        LOADQ   x0, st_step
        bl      sb_int
        LIT     x0, f_fi3
        bl      sb_lit
        mov     x0, x19
        bl      sb_lit
        LIT     x0, f_fi4
        bl      sb_lit
        LOADQ   x0, ev_ha_p
        LOADQ   x1, ev_ha_l
        cbnz    x0, 1f
        LIT     x0, s_ok
        mov     x1, #2
1:      bl      sb_bytes
        LIT     x0, f_fi5
        bl      sb_lit
        mov     x0, x20
        bl      sb_lit
        LIT     x0, f_fi6
        bl      sb_lit
        LOADQ   x0, st_used
        bl      sb_int
        LIT     x0, f_mr7
        bl      sb_lit
        LIT     x0, s_nl
        bl      sb_lit
        mov     x0, #1
        bl      sb_flush
        LIT     x0, s_dash
        STOREQ  x0, tr_rf_p, x1
        mov     x0, #1
        STOREQ  x0, tr_rf_l, x1
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret
