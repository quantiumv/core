// SPDX-License-Identifier: MIT

/*
 * qv_dbg -- Debug Mode state for core_pipe (P6).
 *
 * Owns the three flags core.sv keeps for the Debug Module and nothing
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
 * halted; at any other time it is ignored, as core.sv ignores it outside
 * S_DEBUG_HALTED.
 */
module qv_dbg (
    input  logic clk,
    input  logic rst,

    input  logic i_entry,          // a debug entry this cycle (commit)
    input  logic i_halt_entry,     // ... a halt or step one, which consumes the step arm
    input  logic i_resume_req,     // the Debug Module's resume pulse
    input  logic i_dcsr_step,      // dcsr.step, as it is at the resume

    output logic o_in_debug,
    output logic o_stepping,
    output logic o_resume,         // a resume the hart accepts
    output logic o_dm_access_active
);
    logic in_debug_q, stepping_q;

    assign o_resume = i_resume_req && in_debug_q;

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

    assign o_in_debug         = in_debug_q;
    assign o_stepping         = stepping_q;
    assign o_dm_access_active = in_debug_q;
endmodule
