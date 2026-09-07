# SPDX-License-Identifier: MIT
#
# Milestone 10b (EBREAK/JTAG staged plan, full-stack OpenOCD integration):
# the 12-item acceptance checklist, run against verification/openocd/
# sim_main.cpp's remote_bitbang server (a Verilator simulation of the
# real, unmodified design/soc.sv) via quantiumv.cfg. This is the final
# milestone in the whole 10-milestone EBREAK/JTAG plan -- every item
# below was empirically validated interactively before being folded into
# this script (see the milestone's own project-memory entry for the full
# derivation, including two real RTL bugs this integration test itself
# discovered and Milestone 10a/10b fixed: sbcs.sbreadondata/
# abstractauto.autoexecdata being storage-only, and dmstatus.allresumeack
# being unable to survive a single-step's own fast re-halt).
#
# Program addresses below are read back from a real build
# (`riscv64-unknown-elf-objdump -d m10_debug_test.elf`, via
# firmware/Makefile's m10_debug_test target) -- not hand-predicted, since
# crt0.s's own startup sequence length isn't assumed. See
# firmware/m10_debug_test.s's own header for the full control-flow design
# (one genuine "core is really running" haltreq catch at the spin loop,
# every other test region reached via debugger-controlled dpc redirects).

set SPIN         0x40
set SINGLE_STEP  0x44
set SWBP         0x54
set HWBP         0x60

set PASS_COUNT 0
set FAIL_COUNT 0

proc check {name actual expected} {
    global PASS_COUNT FAIL_COUNT
    if {$actual == $expected} {
        puts "PASS: $name"
        incr PASS_COUNT
    } else {
        puts "FAIL: $name -- expected $expected, got $actual"
        incr FAIL_COUNT
    }
}

# `reg <name>` with no value argument returns a whole descriptive line
# ("pc (/64): 0x0000...040"), not a bare number -- this pulls out just
# the trailing hex value so it can be used in an ordinary Tcl
# comparison/expr.
proc regval {name} {
    set s [reg $name]
    regexp {0x[0-9a-fA-F]+} $s hexval
    return $hexval
}

# ---- Item 1: Connect -- IDCODE match (0x00001001) and a successful
# `target examine` already happened via quantiumv.cfg's own `init`
# (jtag newtap ... -expected-id + target create); OpenOCD refuses to
# proceed at all if either fails, so reaching this script is itself the
# proof, made explicit here rather than left implicit.
puts "=== Item 1: Connect ==="
check "IDCODE matched and target examined (reached this script at all)" 1 1

# ---- Item 2: Halt ----
puts "=== Item 2: Halt ==="
halt
check "halt: pc == spin loop address" [regval pc] $SPIN

# ---- Item 4: Read/write GPRs (done here, while halted at spin, before
# item 3 redirects pc elsewhere) ----
puts "=== Item 4: Read/write GPRs ==="
check "GPR read: ra (x1) == 10 (set by main's own setup)" [regval ra] 10
reg t3 0x123456789a
check "GPR write+readback: t3 == 0x123456789a" [regval t3] 0x123456789a

# ---- Item 5: Read/write CSRs including dcsr/dpc ----
puts "=== Item 5: Read/write CSRs (dcsr/dpc) ==="
check "CSR read: dpc == pc (both read the same halted-PC state)" [regval dpc] [regval pc]
check "CSR read: dcsr.xdebugver == 4 (Sdtrig v1.0)" [expr {([regval dcsr] >> 28) & 0xf}] 4

# ---- Item 8: System Bus Access read/write while HALTED ----
puts "=== Item 8: SBA read/write while halted ==="
riscv set_mem_access sysbus
mww 0x1000 0xcafebabe
check "SBA write+read while halted: mem\[0x1000\] == 0xcafebabe" \
    [lindex [read_memory 0x1000 32 1] 0] 0xcafebabe

# ---- Item 9: System Bus Access read/write while RUNNING ----
puts "=== Item 9: SBA read/write while running ==="
resume
sleep 50
mww 0x1004 0xd00dfeed
check "SBA write while running: mem\[0x1004\] == 0xd00dfeed" \
    [lindex [read_memory 0x1004 32 1] 0] 0xd00dfeed
halt
check "halt after the running check: pc == spin loop again" [regval pc] $SPIN

# ---- Item 10: SBA bulk (multi-word) read -- the acceptance item
# Milestone 10a's real sbcs.sbreadondata fix exists to make possible;
# before that fix this would have silently returned word 0 three times.
puts "=== Item 10: SBA bulk (multi-word) read ==="
mww 0x1010 0x11111111
mww 0x1014 0x22222222
mww 0x1018 0x33333333
set bulk [read_memory 0x1010 32 3]
check "SBA bulk read: word 0 == 0x11111111" [lindex $bulk 0] 0x11111111
check "SBA bulk read: word 1 == 0x22222222" [lindex $bulk 1] 0x22222222
check "SBA bulk read: word 2 == 0x33333333" [lindex $bulk 2] 0x33333333

# ---- Item 11 + 12: Program Buffer memory access (Milestone 7) through
# the real transport, plus a bulk read specifically through the progbuf
# path -- Milestone 10a's abstractauto.autoexecdata fix exercised
# independently from item 10's own sbreadondata path above.
puts "=== Item 11+12: Program Buffer memory access + bulk read ==="
riscv set_mem_access progbuf
mww 0x1020 0xaaaa0001
check "progbuf write+read: mem\[0x1020\] == 0xaaaa0001" \
    [lindex [read_memory 0x1020 32 1] 0] 0xaaaa0001
mww 0x1024 0xaaaa0002
mww 0x1028 0xaaaa0003
set pbulk [read_memory 0x1020 32 3]
check "progbuf bulk read: word 0 == 0xaaaa0001" [lindex $pbulk 0] 0xaaaa0001
check "progbuf bulk read: word 1 == 0xaaaa0002" [lindex $pbulk 1] 0xaaaa0002
check "progbuf bulk read: word 2 == 0xaaaa0003" [lindex $pbulk 2] 0xaaaa0003
riscv set_mem_access sysbus

# ---- Item 3: Single-step -- also the acceptance test for the
# dmstatus.allresumeack fix (a single-step's own near-instant re-halt is
# exactly the race that broke the old "= !i_hart_halted" approximation;
# without that fix, `step` below would fail outright with "unable to
# resume hart 0", not merely report a wrong value.
puts "=== Item 3: Single-step ==="
reg pc $SINGLE_STEP
step
check "step #1: pc advanced by exactly one instruction (4 bytes)" [regval pc] [expr {$SINGLE_STEP + 4}]
check "step #1: t0 == 111 (addi t0,x0,111 at single_step_area)" [regval t0] 111
step
check "step #2: pc advanced again" [regval pc] [expr {$SINGLE_STEP + 8}]
check "step #2: t0 == 112 (addi t0,t0,1)" [regval t0] 112

# ---- Item 6: Software breakpoint (ebreak + dcsr.ebreakm) ----
puts "=== Item 6: Software breakpoint ==="
reg pc $SWBP
bp $SWBP 4
resume
sleep 100
check "sw breakpoint hit: pc == swbp_site" [regval pc] $SWBP
check "sw breakpoint hit: dcsr.cause == 1 (ebreak)" [expr {([regval dcsr] >> 6) & 0x7}] 1
rbp $SWBP

# ---- Item 7: Hardware breakpoint (Milestone 9's Trigger Module) --
# armed BEFORE resuming past the just-removed software breakpoint, so
# execution naturally flows straight through the recovered original
# instruction (proving resume-past-a-removed-sw-bp works, t1==222) and
# into the hardware breakpoint.
puts "=== Item 7: Hardware breakpoint ==="
bp $HWBP 4 hw
resume
sleep 100
check "hw breakpoint hit: pc == hwbp_site" [regval pc] $HWBP
check "hw breakpoint hit: dcsr.cause == 2 (trigger, not ebreak)" [expr {([regval dcsr] >> 6) & 0x7}] 2
check "resume-past-the-removed-sw-bp worked: t1 == 222" [regval t1] 222
rbp $HWBP

# Final resume, past the removed hardware breakpoint, into the program's
# own trailing (real) ebreak -- confirms resume-past-a-removed-hw-bp
# works too (t2==333), and that an ordinary ebreak still correctly
# enters Debug Mode (dcsr.ebreakm, set by OpenOCD's own examine
# sequence) rather than taking a real synchronous trap.
resume
sleep 100
check "final ebreak reached: dcsr.cause == 1 (ebreak)" [expr {([regval dcsr] >> 6) & 0x7}] 1
check "resume-past-the-removed-hw-bp worked: t2 == 333" [regval t2] 333

puts ""
puts "m10_smoke: $PASS_COUNT passed, $FAIL_COUNT failed"
if {$FAIL_COUNT > 0} {
    puts "m10_smoke: FAILURES PRESENT"
}

shutdown
