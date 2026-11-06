// SPDX-License-Identifier: MIT

/*
 * dbg_props -- SymbiYosys properties for design/pipe/qv_dbg.sv, checked at
 * its ports only (plus the lemmas the induction needs). The environment is
 * the core around it: debug entries only while running, a retirement only
 * for an injected word still in flight, and a run ends with a retirement.
 * Everything else -- the start and resume pulses, dcsr.step, whether the
 * queue has room -- is free.
 *
 * Properties:
 *   - a Program Buffer run implies Debug Mode, even when a start and a
 *     resume arrive in the same cycle (the resume wins, no run begins);
 *   - a resume is accepted only while halted and not running a Program
 *     Buffer, and the Debug Module owns regfile0's port and the CSR port
 *     exactly then (halted, no run);
 *   - a word is injected only during a run, with room in the queue, and
 *     never while the previous one is still in flight (one at a time, so the
 *     pc each word is given is exact);
 *   - the word index starts at 0 with the run, counts the retirements and
 *     stops at the run's last;
 *   - stepping is loaded from dcsr.step by an accepted resume and consumed
 *     by a halt/step entry, and is never touched by a resume that is not
 *     accepted.
 */
module dbg_props (
    input logic clk,
    input logic rst,
    input logic entry, halt_entry,
    input logic resume_req, dcsr_step,
    input logic start,
    input logic pb_commit, pb_end,
    input logic inject_ready
);
    logic in_debug, stepping, resume, dm_access, active, inject;
    logic [3:0] idx;

    qv_dbg dut (
        .clk(clk), .rst(rst),
        .i_entry(entry), .i_halt_entry(halt_entry), .i_resume_req(resume_req), .i_dcsr_step(dcsr_step),
        .i_progbuf_start(start), .i_pb_commit(pb_commit), .i_pb_end(pb_end), .i_inject_ready(inject_ready),
        .o_in_debug(in_debug), .o_stepping(stepping), .o_resume(resume), .o_dm_access_active(dm_access),
        .o_progbuf_active(active), .o_progbuf_pc(idx), .o_inject_valid(inject)
    );

    // ---------------- ghost model ----------------
    reg        init = 1'b1;
    reg        g_debug = 1'b0, g_run = 1'b0, g_flight = 1'b0, g_step = 1'b0;
    reg [3:0]  g_idx = 4'b0;
    wire       accepted_start  = start && g_debug && !g_run && !resume_req;
    wire       accepted_resume = resume_req && g_debug && !g_run;
    always @(posedge clk) begin
        init <= 1'b0;
        if (rst) begin
            g_debug <= 1'b0; g_run <= 1'b0; g_flight <= 1'b0; g_step <= 1'b0; g_idx <= 4'b0;
        end else begin
            if (entry)                g_debug <= 1'b1;
            else if (accepted_resume) g_debug <= 1'b0;
            if (accepted_resume)      g_step <= dcsr_step;
            else if (halt_entry)      g_step <= 1'b0;
            if (accepted_start)       g_run <= 1'b1;
            else if (pb_end)          g_run <= 1'b0;
            if (accepted_start)       g_idx <= 4'b0;
            else if (pb_commit && !pb_end) g_idx <= g_idx + 4'b1;
            if (pb_commit)            g_flight <= 1'b0;
            else if (inject)          g_flight <= 1'b1;
        end
    end

    // ---------------- environment ----------------
    always @* begin
        if (init) assume (rst);
        if (!rst) begin
            assume (!entry || !dut.in_debug_q);                 // the core enters Debug Mode from running only
            assume (!halt_entry || entry);
            assume (!pb_commit || (dut.active_q && g_flight));  // only an injected word retires, in a run
            assume (!pb_end || pb_commit);
        end
    end

    // ---------------- properties ----------------
    always @* begin
        if (!rst && !init) begin
            assert (in_debug == g_debug);
            assert (!active || in_debug);
            assert (active == g_run);
            assert (resume == accepted_resume);
            assert (dm_access == (in_debug && !active));
            assert (stepping == g_step);
            assert (!inject || (active && !g_flight && inject_ready));
            if (active) assert (idx == g_idx);
        end
        // induction lemmas: the internals follow the ghosts
        if (!rst && !init) begin
            assert (dut.in_debug_q == g_debug);
            assert (dut.active_q == g_run);
            assert (dut.outstanding_q == g_flight);
            assert (dut.idx_q == g_idx);
            assert (dut.stepping_q == g_step);
            if (!g_run) assert (!g_flight);
        end
    end

    // ---------------- non-vacuity (sby cover task) ----------------
    always @* begin
        if (!rst && !init) begin
            cover (inject && g_idx == 4'd3);                    // a run that got to its fourth word
            cover (pb_commit && pb_end && g_idx == 4'd2);       // a run that ended after three
            cover (accepted_resume && dcsr_step);               // a resume that arms a step
            cover (halt_entry && g_step);                       // a step consumed
            cover (start && resume_req && g_debug && !g_run);   // a start and a resume together
            cover (resume_req && g_run);                        // a resume during a run
        end
    end
endmodule
