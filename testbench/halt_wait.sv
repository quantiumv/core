// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Shared task: wait_halted_or_timeout -- halt-or-timeout wait
 *
 * `include-able, not a module -- pulled in textually via `include
 * "halt_wait.sv" inside a caller's own module body, so
 * wait_halted_or_timeout resolves the including module's own local
 * signals through ordinary Verilog scoping, no arguments needed for that
 * part. Same mechanism as check_lib.sv/wb_driver.sv: SV interfaces fail
 * to parse in this Icarus build and `ref` task arguments aren't supported
 * ("sorry: Reference ports not supported yet."), so a shared task can't
 * take a caller's signals by reference -- it has to reach them by name,
 * the same way this file reaches the required-signal contract below.
 * Resolved via a bare filename in the `include plus an explicit
 * -I testbench flag on the iverilog command line -- Icarus does NOT
 * resolve `include relative to the including file, only via -I.
 *
 * Generalizes the fork/wait(halted)/timeout/$finish shape that was
 * hand-duplicated, with drifting timeout literals (150/200/300/3000),
 * across all 9 core-instantiating testbenches -- see
 * testbench/core_wb_tb.sv:141-149 for the original shape this was lifted
 * from.
 *
 * Required signal contract -- the including module must declare both of
 * these, with these exact names, before the `include line:
 *   clk     -- the free-running clock this testbench drives.
 *   halted  -- a wire tied to the DUT's halt signal, at whatever
 *     hierarchy depth that particular wiring puts it at, e.g.:
 *       wire halted = dut.halted;         // core instantiated directly
 *       wire halted = dut.core0.halted;   // core reached through a
 *                                         // wrapper (soc.sv,
 *                                         // core_wb4_sram_harness.sv)
 *
 * Three tiered timeout budgets are provided instead of one global
 * constant -- one constant would be either too tight for real firmware or
 * absurdly loose for a 12-instruction test:
 *   TIMEOUT_CYCLES_TINY  (150)  -- short hand-assembled programs, a
 *     couple dozen instructions, no loops (e.g. core_wb_tb.sv and the
 *     other single-feature core_*_tb.sv files).
 *   TIMEOUT_CYCLES_SMALL (300)  -- somewhat longer hand-assembled or
 *     real-toolchain-assembled programs -- more instructions or a few
 *     extra bus round trips, still no sustained looping (e.g.
 *     core_zicsr_tb.sv, core_csr_toolchain_tb.sv).
 *   TIMEOUT_CYCLES_LARGE (3000) -- real firmware, e.g. an -O0 C build
 *     that reloads everything from the stack constantly -- needs real
 *     headroom, not just margin (e.g. soc_tb.sv's hello-world
 *     regression).
 *
 * Usage: after declaring clk/halted as above,
 *   `include "halt_wait.sv"
 *   ...
 *   initial begin
 *       ...
 *       wait_halted_or_timeout(`TIMEOUT_CYCLES_TINY, "dut.halted never went high");
 *       // the task already applies the post-join_any #1 settle delay
 *       // every original call site used -- no need to repeat it here
 *       ...
 *   end
 */

`define TIMEOUT_CYCLES_TINY  150
`define TIMEOUT_CYCLES_SMALL 300
`define TIMEOUT_CYCLES_LARGE 3000

// Deliberately NOT `task automatic` -- confirmed by direct test that an
// automatic task wrapping this exact fork/join_any body crashes Icarus
// 13.0 with an internal VVP assertion (vthread.cc:3793,
// of_JOIN_DETACH: "child->wt_context==0 || thr->wt_context!=
// child->wt_context"). The identical fork/join_any body inside a plain
// (static-lifetime) task runs correctly. Static lifetime is safe here
// regardless: this task is never called reentrantly (each caller invokes
// it once, sequentially, from its own top-level initial block).
task wait_halted_or_timeout(input int cycles, input string context_msg);
    fork
        wait (halted === 1'b1);
        begin
            repeat (cycles) @(posedge clk);
            $display("TIMEOUT: %s", context_msg);
            $finish;
        end
    join_any
    #1; // settle delay, identical across all 9 original call sites
endtask


/* ------------------------------------------------------------------------- */


/* End of file. */
