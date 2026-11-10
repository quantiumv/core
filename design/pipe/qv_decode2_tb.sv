// SPDX-License-Identifier: MIT

/*
 * qv_decode2_tb -- the IQ (qv_fifo with its second pop) and the two-slot decode stage (qv_decode2) together, under
 * random traffic: the frontend pushes none, one or two instructions a cycle when the IQ has room, issue takes 0, 1 or 2
 * held uops (2 only when both are held, 1 only when slot 0 is), and a flush comes now and then. Checked every cycle
 * against the instructions pushed, in order:
 *   - what issues is exactly the next instruction(s) of the stream (pc and raw), so nothing is lost, repeated or
 *     reordered by the shift from slot 1 to slot 0 or by the refill from the IQ's head and the entry behind it;
 *   - slot 1 is never held without slot 0, and is the instruction right behind slot 0's;
 *   - decode keeps up: with both slots free and two in the IQ, both refill in one cycle (the second pop happens);
 *   - after a flush nothing from before it issues.
 * Run once per IQ depth via -P overrides (IQ_DEPTH, SEED).
 */
module qv_decode2_tb #(
    parameter int IQ_DEPTH = 4,
    parameter int SEED     = 1
);
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---------------- DUT: IQ + decode ----------------
    logic       push0, push1, push_ready, push_ready1, flush;
    fe_instr_t  pd0, pd1;
    logic       iq_valid, iq1_valid, iq_pop, iq_pop2;
    fe_instr_t  iq_data, iq1_data;
    logic       v0, v1;
    uop_t       u0, u1;
    logic [1:0] issue_n;

    qv_fifo #(.DEPTH(IQ_DEPTH), .WIDTH($bits(fe_instr_t))) iq0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_push0_valid(push0), .i_push0_data(pd0), .i_push1_valid(push1), .i_push1_data(pd1),
        .o_push_ready(push_ready), .o_push_ready1(push_ready1),
        .o_head_valid(iq_valid), .o_head_data(iq_data), .i_pop(iq_pop),
        .o_head1_valid(iq1_valid), .o_head1_data(iq1_data), .i_pop2(iq_pop2)
    );

    qv_decode2 dec0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_priv(2'b11), .i_tsr(1'b0), .i_tvm(1'b0), .i_fs(2'b00), .i_frm(3'b000),
        .i_mcounteren(3'b0), .i_scounteren(3'b0), .i_in_debug(1'b0), .i_pb_active(1'b0),
        .i_tdata1_0(64'd0), .i_tdata2_0(64'd0), .i_tdata1_1(64'd0), .i_tdata2_1(64'd0),
        .i_pmpcfg0(64'd0), .i_pmpaddr0(64'd0), .i_pmpaddr1(64'd0), .i_pmpaddr2(64'd0), .i_pmpaddr3(64'd0),
        .i_iq_valid(iq_valid), .i_iq_data(iq_data), .i_iq1_valid(iq1_valid), .i_iq1_data(iq1_data),
        .o_iq_pop(iq_pop), .o_iq_pop2(iq_pop2),
        .o_valid(v0), .o_uop(u0), .o_valid1(v1), .o_uop1(u1), .i_issue_n(issue_n)
    );

    // ---------------- the stream ----------------
    localparam int QN = 4096;
    logic [63:0] q_pc  [0:QN-1];      // pushed and not yet issued, in order (a ring: head qh, tail qt)
    logic [31:0] q_raw [0:QN-1];
    int qh, qt;
    logic [63:0] next_pc;
    int n_pushed, n_issued, n_pairs, n_pop2, n_flush, errs;

    // a random instruction word: an OP-IMM or OP (decodes to an ALU uop) or anything at all (decodes to a fault)
    function automatic logic [31:0] rnd_raw();
        logic [31:0] r;
        r = $urandom;
        case ($urandom % 3)
            0: r[6:0] = 7'b0010011;
            1: begin r[6:0] = 7'b0110011; r[31:25] = 7'b0; end
            default: ;
        endcase
        if (r[1:0] != 2'b11) r[1:0] = 2'b11;            // 32-bit words only (the frontend's job, not decode's)
        return r;
    endfunction

    function automatic fe_instr_t mk_fe(input logic [63:0] pc, input logic [31:0] raw);
        fe_instr_t f;
        f     = '0;
        f.pc  = pc;
        f.raw = raw;
        return f;
    endfunction

    // the driver: chosen at the negative edge, applied through the next positive edge
    logic run_en = 1'b0;
    int   p_push, p_issue2, p_flush;
    always @(negedge clk) begin
        push0   <= 1'b0;
        push1   <= 1'b0;
        issue_n <= 2'd0;
        flush   <= 1'b0;
        if (!rst && run_en) begin
            if (($urandom % 1000) < p_flush) begin
                flush <= 1'b1;
            end else begin
                int np;
                np = ($urandom % 100 < p_push) ? (($urandom % 2) ? 2 : 1) : 0;
                if (np == 2 && !push_ready) np = push_ready1 ? 1 : 0;
                if (np == 1 && !push_ready1) np = 0;
                if (np >= 1) begin push0 <= 1'b1; pd0 <= mk_fe(next_pc, rnd_raw()); end
                if (np == 2) begin push1 <= 1'b1; pd1 <= mk_fe(next_pc + 64'd4, rnd_raw()); end
                if (v0) begin
                    if (v1 && ($urandom % 100 < p_issue2)) issue_n <= 2'd2;
                    else if ($urandom % 4 != 0)            issue_n <= 2'd1;
                end
            end
        end
    end

    // the model and the checks, at the positive edge (the DUT's outputs are this cycle's)
    always @(posedge clk) begin
        if (!rst && run_en) begin
            if (v1 && !v0) begin
                errs++;
                $display("ERR cyc %0d: slot 1 held without slot 0", cyc);
            end
            if (v0 && v1 && u1.pc != u0.pc + 64'd4) begin
                errs++;
                if (errs < 6) $display("ERR cyc %0d: slot 1 (pc %h) is not right behind slot 0 (pc %h)", cyc, u1.pc, u0.pc);
            end
            if (flush) begin
                qh = qt;                                     // everything pushed and not issued is gone
                next_pc = {next_pc[63:12] + 52'd1, 12'h000}; // the redirect target: a new page
                n_flush++;
            end else begin
                if (issue_n >= 2'd1) begin
                    if (qh == qt || u0.pc != q_pc[qh % QN] || u0.raw != q_raw[qh % QN]) begin
                        errs++;
                        if (errs < 6) $display("ERR cyc %0d: slot 0 issued pc %h raw %h, expected pc %h raw %h", cyc,
                                               u0.pc, u0.raw, q_pc[qh % QN], q_raw[qh % QN]);
                    end
                    qh++;
                    n_issued++;
                end
                if (issue_n == 2'd2) begin
                    if (qh == qt || u1.pc != q_pc[qh % QN] || u1.raw != q_raw[qh % QN]) begin
                        errs++;
                        if (errs < 6) $display("ERR cyc %0d: slot 1 issued pc %h raw %h, expected pc %h raw %h", cyc,
                                               u1.pc, u1.raw, q_pc[qh % QN], q_raw[qh % QN]);
                    end
                    qh++;
                    n_issued++;
                    n_pairs++;
                end
                if (push0) begin q_pc[qt % QN] = pd0.pc; q_raw[qt % QN] = pd0.raw; qt++; n_pushed++; next_pc = pd0.pc + 64'd4; end
                if (push1) begin q_pc[qt % QN] = pd1.pc; q_raw[qt % QN] = pd1.raw; qt++; n_pushed++; next_pc = pd1.pc + 64'd4; end
                if (iq_pop2) n_pop2++;
                // decode keeps up: both slots free after this cycle's issue and two waiting means both are taken
                if (iq_valid && iq1_valid && (!v0 || issue_n == 2'd2 || (issue_n == 2'd1 && !v1)) && !iq_pop2) begin
                    errs++;
                    if (errs < 6) $display("ERR cyc %0d: two in the IQ, both slots free, and no second pop", cyc);
                end
                if (iq_pop2 && !iq_pop) begin
                    errs++;
                    $display("ERR cyc %0d: a second pop without the first", cyc);
                end
            end
        end
    end

    task automatic run(input string tag, input int cycles, input int pp, input int pi2, input int pf);
        p_push = pp; p_issue2 = pi2; p_flush = pf;
        run_en = 1'b0;
        rst = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        qh = 0; qt = 0; next_pc = 64'h1000; errs = 0;
        n_pushed = 0; n_issued = 0; n_pairs = 0; n_pop2 = 0; n_flush = 0;
        rst = 1'b0;
        run_en = 1'b1;
        repeat (cycles) @(posedge clk);
        run_en = 1'b0;
        #1;
        $display("qv_decode2_tb %s: %0d pushed, %0d issued (%0d pairs), %0d second pops, %0d flushes", tag, n_pushed,
                 n_issued, n_pairs, n_pop2, n_flush);
        check({tag, ": the stream issued in order, nothing lost or repeated"}, 64'(errs), 64'd0);
        check({tag, ": instructions issued"}, 64'(n_issued > cycles / 8), 64'd1);
        if (pi2 > 0) check({tag, ": pairs issued"}, 64'(n_pairs > cycles / 50), 64'd1);
        check({tag, ": second pops happened"}, 64'(n_pop2 > 0), 64'd1);
        if (pf > 0) check({tag, ": flushes happened"}, 64'(n_flush > 0), 64'd1);
    endtask

    int seed_v = SEED;
    initial begin
        void'($urandom(seed_v));
        push0 = 1'b0; push1 = 1'b0; issue_n = 2'd0; flush = 1'b0;
        run("busy frontend, pairs often", 20000, 90, 70, 0);
        run("busy frontend, few pairs", 20000, 90, 10, 0);
        run("slow frontend", 20000, 35, 60, 0);
        run("with flushes", 30000, 80, 50, 8);
        $display("");
        $display("qv_decode2_tb (IQ_DEPTH=%0d): %0d passed, %0d failed", IQ_DEPTH, pass_count, fail_count);
        if (fail_count > 0) $display("qv_decode2_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT: qv_decode2_tb");
        $finish;
    end
endmodule
