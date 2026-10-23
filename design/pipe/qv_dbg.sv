// SPDX-License-Identifier: MIT

/*
 * qv_dbg -- Debug Mode state for the core (P6).
 *
 * Owns the three flags ref_core.sv keeps for the Debug Module and nothing
 * else; the decisions (when a halt, step, EBREAK or trigger actually
 * enters Debug Mode) are commit's, because they have to be taken at a
 * retirement boundary or at the ROB head:
 *
 *   in_debug    set by any debug entry, cleared by an accepted resume.
 *               While it is set the hart is halted: fetch is held, the
 *               pipeline is empty, and the Debug Module owns regfile0's
 *               read port B and write port and csr_file0's CSR port
 *               (dm_access_active).
 *   stepping    armed by a resume when dcsr.step is set at that moment
 *               (re-read on every resume, so it is sticky exactly as long
 *               as the debugger leaves dcsr.step on) and consumed by the
 *               next halt entry, which commit takes at the first sample
 *               point after one retirement: a single step. While it is set
 *               commit takes no interrupt.
 *
 * Resume (a one-cycle pulse from the Debug Module) is accepted only while
 * halted and not running a Program Buffer; at any other time it is ignored,
 * as ref_core.sv ignores it outside S_DEBUG_HALTED.
 *
 * Program Buffer: a start pulse while halted begins a run. The words are
 * injected into the instruction queue one at a time -- the next only once
 * the previous has retired, so the pc each one is given (the architectural,
 * drifting pc) is exact whatever the previous one did. The Debug Module hands
 * over word number o_progbuf_pc (it reads its storage combinationally); that
 * index counts the retirements, one slot per instruction, and stops at the
 * run's last (an EBREAK, or an exception). While a run is active the hart is
 * still in Debug Mode, but the Debug Module does not own regfile0's port or
 * the CSR port: the injected instructions do.
 */
module qv_dbg (
    input  logic clk,
    input  logic rst,

    input  logic i_entry,          // a debug entry this cycle (commit)
    input  logic i_halt_entry,     // ... a halt or step one, which consumes the step arm
    input  logic i_resume_req,     // the Debug Module's resume pulse
    input  logic i_dcsr_step,      // dcsr.step, as it is at the resume

    // Program Buffer
    input  logic i_progbuf_start,  // the Debug Module's start pulse
    input  logic i_pb_commit,      // an injected instruction retires this cycle (commit)
    input  logic i_pb_end,         // ... and it is the run's last (done or abort)
    input  logic i_inject_ready,   // the instruction queue has room

    output logic o_in_debug,
    output logic o_stepping,
    output logic o_resume,         // a resume the hart accepts
    output logic o_dm_access_active,
    output logic o_progbuf_active,
    output logic [3:0] o_progbuf_pc,
    output logic o_inject_valid    // push the word the Debug Module presents (for index o_progbuf_pc) now
);
    logic in_debug_q, stepping_q, active_q, outstanding_q;
    logic [3:0] idx_q;

    assign o_resume = i_resume_req && in_debug_q && !active_q;

    always_ff @(posedge clk) begin
        if (rst)           in_debug_q <= 1'b0;
        else if (i_entry)  in_debug_q <= 1'b1;
        else if (o_resume) in_debug_q <= 1'b0;
    end

    always_ff @(posedge clk) begin
        if (rst)                 stepping_q <= 1'b0;
        else if (o_resume)       stepping_q <= i_dcsr_step;
        else if (i_halt_entry)   stepping_q <= 1'b0;
    end

    // a resume wins a same-cycle start (the Debug Module can't produce both), which keeps active_q implying
    // in_debug_q
    always_ff @(posedge clk) begin
        if (rst)                                                                active_q <= 1'b0;
        else if (i_progbuf_start && in_debug_q && !active_q && !i_resume_req)   active_q <= 1'b1;
        else if (i_pb_end)                                                      active_q <= 1'b0;
    end

    // the word index: 0 at the start, +1 per retirement, except the last
    always_ff @(posedge clk) begin
        if (rst)                                                                idx_q <= 4'b0;
        else if (i_progbuf_start && in_debug_q && !active_q && !i_resume_req)   idx_q <= 4'b0;
        else if (i_pb_commit && !i_pb_end)                                      idx_q <= idx_q + 4'b1;
    end

    // one injected instruction in flight at a time
    assign o_inject_valid = active_q && !outstanding_q && i_inject_ready;
    always_ff @(posedge clk) begin
        if (rst)                  outstanding_q <= 1'b0;
        else if (i_pb_commit)     outstanding_q <= 1'b0;
        else if (o_inject_valid)  outstanding_q <= 1'b1;
    end

    assign o_in_debug         = in_debug_q;
    assign o_stepping         = stepping_q;
    assign o_progbuf_active   = active_q;
    assign o_progbuf_pc       = idx_q;
    assign o_dm_access_active = in_debug_q && !active_q;
endmodule
