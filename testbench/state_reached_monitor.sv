// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: state_reached_monitor
 *
 * A real module, not `include-able -- same reasoning as
 * pc_trigger_sample_monitor.sv: it's a standing concurrent process, not
 * a one-shot task a caller invokes at a chosen point.
 *
 * Generalizes a narrower pattern than pc_trigger_sample_monitor.sv
 * covers: "did the DUT ever reach this state, at any PC" -- no PC
 * target, no sampled signal value, just a sticky "was it ever true"
 * flag. pc_trigger_sample_monitor.sv can't express this directly (its
 * i_pc_target comparison is mandatory, not optional), and generalizing
 * it to support an "ignore pc" mode would be a real change to an
 * existing, already-used shared module for a need it was never meant
 * to cover -- a new, narrower module is the correct-sized fix.
 *
 * Introduced to deduplicate a hand-written `amo_write_entered` latch
 * that testbench/core_bus_fault_trap_tb.sv and
 * testbench/core_bus_fault_cache_tb.sv each independently wrote (both
 * proving an AMO read-phase fault never lets the FSM proceed into
 * S_AMO_WRITE) -- found via code review of the bus-error-trapping
 * milestone: two copies of the same 5-line block is exactly the
 * duplication pc_trigger_sample_monitor.sv's own header cites as the
 * thing worth generalizing away from.
 *
 * Sampled on negedge clk, same race-free reasoning as
 * pc_trigger_sample_monitor.sv: state is stable for the whole cycle
 * once it settles after a synchronous DUT's posedge, so negedge is a
 * safe place to look without racing the DUT's own state register.
 *
 * Parameters:
 *  STATE_WIDTH: Bit width of the state/target comparison (default = 3,
 *    matching core.sv's current state_t enum).
 *
 * Input ports:
 *  clk: Clock signal the trigger is sampled against (negedge).
 *  i_state: The DUT's current state (e.g. dut.core0.state).
 *  i_state_target: The state value that counts as "reached"
 *    (e.g. dut.core0.S_AMO_WRITE).
 *
 * Output ports:
 *  o_reached: High from the first cycle i_state == i_state_target is
 *    ever seen, for the rest of the simulation. Never clears.
 *
 * Worked example -- collapses a hand-written block like:
 *   logic amo_write_entered = 1'b0;
 *   always @(posedge clk) begin
 *       if (dut.core0.state == dut.core0.S_AMO_WRITE)
 *           amo_write_entered <= 1'b1;
 *   end
 * into:
 *   logic amo_write_entered;
 *   state_reached_monitor amo_write_monitor (
 *       .clk(clk), .i_state(dut.core0.state),
 *       .i_state_target(dut.core0.S_AMO_WRITE), .o_reached(amo_write_entered)
 *   );
 */
module state_reached_monitor #(
    parameter STATE_WIDTH = 3
) (
    input  logic                       clk,
    input  logic [(STATE_WIDTH - 1):0] i_state,
    input  logic [(STATE_WIDTH - 1):0] i_state_target,
    output logic                       o_reached
);
    /*
     * Simulation-only zero-fill, same reasoning and same idiom as
     * pc_trigger_sample_monitor.sv/register_file.sv/wb4_sram.sv: keeps
     * "not reached yet" a clean, checkable 0 instead of 'X.
     */
    initial begin
        o_reached = 1'b0;
    end

    always @(negedge clk) begin
        if (i_state == i_state_target)
            o_reached = 1'b1;
    end
endmodule: state_reached_monitor


/* ------------------------------------------------------------------------- */


/* End of file. */
