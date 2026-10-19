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
 *     port) follows in_debug, except while a Program Buffer run is active
 *   - the Program Buffer: a start pulse while halted begins a run; one word
 *     is injected at a time, only once the previous has retired and only when
 *     the queue has room; the slot index counts the retirements and stops at
 *     the run's last; a resume is ignored while a run is active, a start is
 *     ignored when not halted or already running, and a resume wins a start
 *     in the same cycle
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
    logic start = 1'b0, pb_commit = 1'b0, pb_end = 1'b0, inject_ready = 1'b1;
    logic in_debug, stepping, resume, dm_access, active, inject;
    logic [3:0] idx;

    qv_dbg dut (
        .clk(clk), .rst(rst),
        .i_entry(entry), .i_halt_entry(halt_entry), .i_resume_req(resume_req), .i_dcsr_step(dcsr_step),
        .i_progbuf_start(start), .i_pb_commit(pb_commit), .i_pb_end(pb_end), .i_inject_ready(inject_ready),
        .o_in_debug(in_debug), .o_stepping(stepping), .o_resume(resume), .o_dm_access_active(dm_access),
        .o_progbuf_active(active), .o_progbuf_pc(idx), .o_inject_valid(inject)
    );

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    task automatic cycle();
        @(posedge clk); #1;
        entry = 1'b0; halt_entry = 1'b0; resume_req = 1'b0; start = 1'b0; pb_commit = 1'b0; pb_end = 1'b0;
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

        // ---------------- Program Buffer ----------------
        // a start while running is ignored
        start = 1'b1;
        cycle();
        check("start while running: no run", b(active), 64'd0);
        entry = 1'b1; halt_entry = 1'b1;
        cycle();
        check("halted for the Program Buffer", b(in_debug), 64'd1);
        check("halted: no run yet", b(active), 64'd0);
        check("halted, no run: the Debug Module owns the ports", b(dm_access), 64'd1);
        #1;
        check("halted, no run: nothing injected", b(inject), 64'd0);

        // start: the run begins, slot 0, and the Debug Module no longer owns the ports
        start = 1'b1;
        cycle();
        check("run: active", b(active), 64'd1);
        check("run: still in Debug Mode", b(in_debug), 64'd1);
        check("run: slot 0", {60'b0, idx}, 64'd0);
        check("run: the Debug Module doesn't own the ports", b(dm_access), 64'd0);
        #1;
        check("run: the first word is injected", b(inject), 64'd1);
        // one word in flight at a time
        cycle();
        #1;
        check("word in flight: no second injection", b(inject), 64'd0);
        cycle();
        #1;
        check("word in flight, a cycle later: still none", b(inject), 64'd0);
        // it retires: the index moves on and the next word goes in
        pb_commit = 1'b1;
        cycle();
        check("after the first retirement: slot 1", {60'b0, idx}, 64'd1);
        #1;
        check("after the first retirement: the next word is injected", b(inject), 64'd1);
        // a full queue holds the next injection back
        inject_ready = 1'b0;
        #1;
        check("no room in the queue: nothing injected", b(inject), 64'd0);
        cycle();
        check("no room in the queue: the run goes on", b(active), 64'd1);
        inject_ready = 1'b1;
        #1;
        check("room again: injected", b(inject), 64'd1);
        // an injected word retires: the index moves on
        cycle();                                           // injected (in flight)
        pb_commit = 1'b1;
        cycle();
        check("slot 2", {60'b0, idx}, 64'd2);
        // a resume is ignored while the run is active
        resume_req = 1'b1;
        #1;
        check("resume during a run: not accepted", b(resume), 64'd0);
        cycle();
        check("resume during a run: still in Debug Mode", b(in_debug), 64'd1);
        check("resume during a run: still running", b(active), 64'd1);
        // a second start while running changes nothing (the index is not restarted)
        start = 1'b1;
        cycle();
        check("start during a run: the index is kept", {60'b0, idx}, 64'd2);
        // the run's last instruction: the index stays, the run ends, nothing more is injected
        #1;
        check("the last word is in flight: nothing more is injected", b(inject), 64'd0);
        pb_commit = 1'b1; pb_end = 1'b1;
        cycle();
        check("run over: inactive", b(active), 64'd0);
        check("run over: the index stays on the last slot", {60'b0, idx}, 64'd2);
        check("run over: back in Debug Mode proper", b(in_debug), 64'd1);
        check("run over: the Debug Module owns the ports again", b(dm_access), 64'd1);
        #1;
        check("run over: nothing injected", b(inject), 64'd0);
        cycle();
        #1;
        check("run over, a cycle later: nothing injected", b(inject), 64'd0);

        // a new run restarts at slot 0
        start = 1'b1;
        cycle();
        check("second run: slot 0 again", {60'b0, idx}, 64'd0);
        check("second run: active", b(active), 64'd1);
        // the index wraps (4 bits) if a run is 16 words long without an end
        for (int i = 0; i < 16; i++) begin
            cycle();                                       // inject
            pb_commit = 1'b1;
            cycle();
        end
        check("sixteen retirements without an end: the index wrapped", {60'b0, idx}, 64'd0);
        pb_commit = 1'b1; pb_end = 1'b1;
        cycle();
        check("ended", b(active), 64'd0);

        // a resume wins a start in the same cycle (the Debug Module can't produce both)
        start = 1'b1; resume_req = 1'b1;
        #1;
        check("resume + start: the resume is accepted", b(resume), 64'd1);
        cycle();
        check("resume + start: running again", b(in_debug), 64'd0);
        check("resume + start: no run", b(active), 64'd0);
        // and a start right after a resume, while running, is ignored
        start = 1'b1;
        cycle();
        check("start after the resume: ignored", b(active), 64'd0);

        // reset in the middle of a run clears it
        entry = 1'b1; halt_entry = 1'b1;
        cycle();
        start = 1'b1;
        cycle();
        check("run again: active", b(active), 64'd1);
        rst = 1'b1;
        cycle();
        rst = 1'b0;
        check("reset: no run", b(active), 64'd0);
        check("reset: idx 0", {60'b0, idx}, 64'd0);
        #1;
        check("reset: nothing injected", b(inject), 64'd0);

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
