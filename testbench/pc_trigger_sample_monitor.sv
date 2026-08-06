// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: pc_trigger_sample_monitor
 *
 * A real module, not `include-able -- unlike this session's other new
 * shared testbench files, this one is a standing concurrent process (it
 * must keep watching every cycle for its trigger condition), not a
 * one-shot task a caller invokes at a chosen point.
 *
 * Generalizes the white-box PC-triggered signal-sampling pattern that
 * testbench/core_zicsr_tb.sv hand-duplicated 3x within a single file
 * (once per CSR write-suppression case it wanted to prove true via
 * hierarchical inspection, not just via register-value side effects).
 * Each instance watches one (state, pc) combination and latches one
 * signal the first cycle it sees that combination hold.
 *
 * Sampled on negedge clk, well clear of the posedge that drives the
 * DUT's own state register: state (and everything combinationally
 * derived from it, including whatever i_sample is wired to) is stable
 * for the entire cycle once state has settled, so negedge is a
 * race-free place to look. This edge choice is hardcoded, not a
 * parameter -- it isn't a style preference, it's a correctness property
 * of sampling *after* a synchronous DUT's posedge-driven state has
 * settled but *before* the next posedge changes it. A caller that
 * wanted a different edge would need a DUT whose relevant state changes
 * on the opposite edge, which nothing in this project does; exposing it
 * as a knob would only let it be set wrong.
 *
 * WIDTH (default 1) is parameterized even though every current
 * consumer samples a single bit (core_zicsr_tb.sv's dut.csr_we) because
 * this is meant to outlive this milestone: the target-architecture
 * roadmap's next steps (privilege modes, Sv39) will introduce
 * multi-bit signals worth this same kind of white-box, PC-triggered
 * capture -- a privilege-level field or an Sv39 walk-state encoding,
 * for example -- and there is no reason this monitor's shape should
 * need to be re-derived when that day comes.
 *
 * LATCH_FIRST_ONLY (default 1) matches every current use: this
 * project's testbenches assemble straight-line programs where a given
 * PC executes at most once, so "capture the first match and ignore
 * everything after" and "capture the only match there will ever be"
 * are the same thing in practice, and the stronger one-shot guarantee
 * is the safer default -- it also catches the case where the trigger
 * condition unexpectedly holds across more than one cycle (a stall, a
 * decode bug) without silently clobbering the first, real sample with
 * a later, spurious one. Set to 0 for a future loop-shaped test program
 * where the same PC really is expected to recur and each occurrence
 * should overwrite o_sampled with the latest value.
 *
 * Parameters:
 *  WIDTH: Bit width of the sampled signal (default = 1).
 *  PC_WIDTH: Bit width of the PC/target comparison (default = 64,
 *    matching `WORD_SIZE).
 *  STATE_WIDTH: Bit width of the state/target comparison (default = 2,
 *    matching core.sv's state_t enum).
 *  LATCH_FIRST_ONLY: When 1 (default), only the first matching cycle
 *    latches; later matches are ignored. When 0, every matching cycle
 *    re-latches o_sampled with the current i_sample.
 *
 * Input ports:
 *  clk: Clock signal the trigger is sampled against (negedge).
 *  i_state: The DUT's current state (e.g. dut.state).
 *  i_state_target: The state value that must hold for a match.
 *  i_pc: The DUT's current PC (e.g. dut.pc).
 *  i_pc_target: The PC value that must hold for a match.
 *  i_sample: The signal to latch on a match (e.g. dut.csr_we).
 *
 * Output ports:
 *  o_sampled: The latched value of i_sample, valid once o_captured is 1.
 *  o_captured: High once at least one matching cycle has been seen.
 *
 * Worked example -- collapses core_zicsr_tb.sv's original hand-written
 * block:
 *   localparam logic [63:0] PC_RS1_X0_CHECK = 64'h34;
 *   logic csr_we_sampled;
 *   logic csr_we_sample_captured = 1'b0;
 *   always @(negedge clk) begin
 *       if (!csr_we_sample_captured && dut.state == 2'd1 &&
 *           dut.pc == PC_RS1_X0_CHECK) begin
 *           csr_we_sampled = dut.csr_we;
 *           csr_we_sample_captured = 1'b1;
 *       end
 *   end
 * into:
 *   pc_trigger_sample_monitor rs1_x0_monitor (
 *       .clk(clk), .i_state(dut.state), .i_state_target(2'd1),
 *       .i_pc(dut.pc), .i_pc_target(64'h34), .i_sample(dut.csr_we),
 *       .o_sampled(csr_we_sampled), .o_captured(csr_we_sample_captured)
 *   );
 */
module pc_trigger_sample_monitor #(
    parameter WIDTH             = 1,
    parameter PC_WIDTH          = 64,
    parameter STATE_WIDTH       = 2,
    parameter LATCH_FIRST_ONLY  = 1
) (
    input  logic                       clk,
    input  logic [(STATE_WIDTH - 1):0] i_state,
    input  logic [(STATE_WIDTH - 1):0] i_state_target,
    input  logic [(PC_WIDTH - 1):0]    i_pc,
    input  logic [(PC_WIDTH - 1):0]    i_pc_target,
    input  logic [(WIDTH - 1):0]       i_sample,
    output logic [(WIDTH - 1):0]       o_sampled,
    output logic                       o_captured
);
    /*
     * Simulation-only zero-fill, same reasoning and same idiom as
     * register_file.sv/wb4_sram.sv: real hardware has no defined
     * power-up state, but zeroing here keeps waveform/$display output
     * readable, and here specifically makes "no match seen yet" a
     * clean, checkable 0 instead of 'X for however many cycles precede
     * the first (or only) match. A real initial block, not a port
     * default -- matching those two modules' own precedent rather than
     * an inline port initializer.
     */
    initial begin
        o_captured = 1'b0;
    end

    always @(negedge clk) begin
        if ((!o_captured || (LATCH_FIRST_ONLY == 0)) &&
            i_state == i_state_target && i_pc == i_pc_target) begin
            o_sampled = i_sample;
            o_captured = 1'b1;
        end
    end
endmodule: pc_trigger_sample_monitor


/* ------------------------------------------------------------------------- */


/* End of file. */
