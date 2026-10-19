// SPDX-License-Identifier: MIT

/*
 * qv_dbg_tb -- standalone test for design/pipe/qv_dbg.sv: the Debug Mode
 * flags. Checks the state machine against core.sv's own rules:
 *   - in_debug is set by an entry and cleared by a resume the hart accepts;
 *     a resume at any other time is ignored (it must not touch stepping)
 *   - stepping is loaded from dcsr.step at every accepted resume (so it is
 *     re-armed on each resume for as long as the debugger leaves the bit on),
 *     and consumed by a halt/step entry only
 *   - dm_access_active (the Debug Module owns the register file and the CSR
 *     port) follows in_debug
 */
module qv_dbg_tb;
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic entry = 1'b0, halt_entry = 1'b0, resume_req = 1'b0, dcsr_step = 1'b0;
    logic in_debug, stepping, resume, dm_access;

    qv_dbg dut (
        .clk(clk), .rst(rst),
        .i_entry(entry), .i_halt_entry(halt_entry), .i_resume_req(resume_req), .i_dcsr_step(dcsr_step),
        .o_in_debug(in_debug), .o_stepping(stepping), .o_resume(resume), .o_dm_access_active(dm_access)
    );

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    task automatic cycle();
        @(posedge clk); #1;
        entry = 1'b0; halt_entry = 1'b0; resume_req = 1'b0;
    endtask

    initial begin
        repeat (2) @(posedge clk);
        #1 rst = 1'b0;
        #1;
        check("reset: not in debug", b(in_debug), 64'd0);
        check("reset: not stepping", b(stepping), 64'd0);
        check("reset: no Debug Module access", b(dm_access), 64'd0);

        // a resume while running is ignored: no acceptance, and stepping is not loaded
        dcsr_step = 1'b1; resume_req = 1'b1;
        #1;
        check("resume while running: not accepted", b(resume), 64'd0);
        cycle();
        check("resume while running: still not in debug", b(in_debug), 64'd0);
        check("resume while running: stepping not armed", b(stepping), 64'd0);
        dcsr_step = 1'b0;

        // an entry halts the hart
        entry = 1'b1;
        #1;
        check("entry cycle: not yet in debug", b(in_debug), 64'd0);
        cycle();
        check("after an entry: in debug", b(in_debug), 64'd1);
        check("after an entry: the Debug Module owns the register file and CSR port", b(dm_access), 64'd1);
        check("after an entry: stepping untouched", b(stepping), 64'd0);

        // resume with dcsr.step clear: running again, not stepping
        dcsr_step = 1'b0; resume_req = 1'b1;
        #1;
        check("resume while halted: accepted", b(resume), 64'd1);
        cycle();
        check("after a resume: running", b(in_debug), 64'd0);
        check("after a resume: no Debug Module access", b(dm_access), 64'd0);
        check("resume with dcsr.step clear: not stepping", b(stepping), 64'd0);

        // enter again by a halt, resume with dcsr.step set: stepping is armed
        entry = 1'b1; halt_entry = 1'b1;
        cycle();
        check("halt entry: in debug", b(in_debug), 64'd1);
        dcsr_step = 1'b1; resume_req = 1'b1;
        cycle();
        check("resume with dcsr.step set: running", b(in_debug), 64'd0);
        check("resume with dcsr.step set: stepping armed", b(stepping), 64'd1);

        // the step's own halt entry consumes it
        entry = 1'b1; halt_entry = 1'b1;
        cycle();
        check("step entry: in debug", b(in_debug), 64'd1);
        check("step entry: stepping consumed", b(stepping), 64'd0);

        // sticky: dcsr.step still set, the next resume arms it again
        resume_req = 1'b1;
        cycle();
        check("second resume, dcsr.step still set: stepping armed again", b(stepping), 64'd1);
        entry = 1'b1; halt_entry = 1'b1;
        cycle();
        check("second step entry: consumed again", b(stepping), 64'd0);

        // the debugger clears dcsr.step before resuming: no step
        dcsr_step = 1'b0; resume_req = 1'b1;
        cycle();
        check("resume after clearing dcsr.step: not stepping", b(stepping), 64'd0);

        // an entry that is not a halt/step (EBREAK, trigger) leaves an armed step alone; it is reloaded by the
        // next resume anyway
        dcsr_step = 1'b1; entry = 1'b1; halt_entry = 1'b1;
        cycle();
        resume_req = 1'b1;                            // arm
        cycle();
        check("armed", b(stepping), 64'd1);
        entry = 1'b1;                                 // entry that is not a halt entry
        cycle();
        check("non-halt entry: in debug", b(in_debug), 64'd1);
        check("non-halt entry: an armed step is left alone", b(stepping), 64'd1);
        dcsr_step = 1'b0; resume_req = 1'b1;
        cycle();
        check("the next resume reloads stepping from dcsr.step", b(stepping), 64'd0);

        // an entry while already halted would be a design error, but a resume in the same cycle as an entry
        // can't happen either (entry needs running, resume needs halted): halted + resume only
        entry = 1'b1; halt_entry = 1'b1; cycle();
        check("halted again", b(in_debug), 64'd1);
        resume_req = 1'b1; dcsr_step = 1'b1;
        #1;
        check("resume pulse is combinational", b(resume), 64'd1);
        cycle();
        // reset clears everything
        rst = 1'b1;
        cycle();
        rst = 1'b0;
        check("reset: not in debug", b(in_debug), 64'd0);
        check("reset: stepping cleared", b(stepping), 64'd0);

        $display("");
        $display("qv_dbg_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_dbg_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT: qv_dbg_tb");
        $finish;
    end
endmodule
