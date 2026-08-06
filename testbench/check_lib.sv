// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Shared task: check -- one PASS/FAIL comparison, with tallies
 *
 * `include`-able, not a module -- pulled in textually via `include
 * "check_lib.sv" inside a caller's own module body, so check() resolves
 * the including module's own pass_count/fail_count/quiet_on_pass through
 * ordinary Verilog scoping, no arguments needed for those. This is the
 * only mechanism confirmed to work for sharing testbench logic in this
 * Icarus build: SV interfaces fail to parse here, and `ref` task
 * arguments aren't supported ("sorry: Reference ports not supported
 * yet."), so a shared task can't take a caller's signals by reference --
 * it has to reach them by name, the same way this file reaches the
 * required-signal contract below. Resolved via a bare filename in the
 * `include plus an explicit -I testbench flag on the iverilog command
 * line -- Icarus does NOT resolve `include relative to the including
 * file, only via -I.
 *
 * Required-signal contract -- the including module must declare all of
 * these, with these exact names, before the `include line:
 *   int   pass_count = 0;       -- incremented on every PASS.
 *   int   fail_count = 0;       -- incremented on every FAIL.
 *   logic quiet_on_pass = 1'b0; -- 0: PASS prints like FAIL does (the
 *     project's long-standing default, still what most testbenches want).
 *     1: PASS is tallied silently, only FAIL ever reaches $display -- for
 *     a testbench that calls check() thousands of times (a randomized
 *     sweep, say), where a PASS line per call would drown the log without
 *     adding information a passing final tally doesn't already give.
 *
 * check(name, actual, expected): `===` compare (not `==` -- catches X/Z
 * propagation bugs a 4-state-blind compare would silently pass), tallies
 * into pass_count/fail_count, $display's PASS/FAIL per the contract
 * above. Deliberately takes actual as a plain argument rather than
 * reaching into a DUT's hierarchy itself -- the anti-pattern this
 * generalizes away from is a prior check_reg task that baked a
 * hierarchical dut.regfile0.gp_registers[idx] lookup directly into the
 * checking primitive, coupling it to one specific DUT's instance names.
 * A caller needing a hierarchical value just passes it explicitly:
 *   check("x1", dut.regfile0.gp_registers[1], 64'd5);
 *
 * Worked example -- a minimal including module:
 *   module my_tb;
 *       int   pass_count = 0;
 *       int   fail_count = 0;
 *       logic quiet_on_pass = 1'b0;
 *       `include "check_lib.sv"
 *
 *       initial begin
 *           check("simple pass", 64'd5, 64'd5);
 *           check("simple fail", 64'd5, 64'd6);
 *           $display("%0d/%0d passed", pass_count, pass_count + fail_count);
 *       end
 *   endmodule
 *
 * This is one of five new shared testbench files, all in testbench/, all
 * `include`-able or instantiable exactly like this one -- see each for
 * its own full header:
 *   check_lib.sv (this file)      -- the check() primitive, above.
 *   wb_driver.sv                  -- `include`-able wb_cycle() task, one
 *                                    Wishbone classic bus transaction.
 *   halt_wait.sv                  -- `include`-able wait_halted_or_timeout()
 *                                    task, tiered timeout budgets.
 *   pc_trigger_sample_monitor.sv  -- real module, one-shot signal capture
 *                                    at a given (state, pc).
 *   core_wb4_sram_harness.sv      -- real module, core + wb4_sram wiring
 *                                    for a unit/instruction-level test.
 */
task automatic check(string name, logic [63:0] actual, logic [63:0] expected);
    if (actual === expected) begin
        pass_count++;
        if (!quiet_on_pass) $display("PASS: %s", name);
    end else begin
        fail_count++;
        $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
    end
endtask


/* ------------------------------------------------------------------------- */


/* End of file. */
