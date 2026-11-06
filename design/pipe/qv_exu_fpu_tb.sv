// SPDX-License-Identifier: MIT

/*
 * qv_exu_fpu_tb -- qv_exu_fpu's control, with the real datapath: random streams of ops drawn from the smoke vectors
 * (so every result is also checked), divides and square roots overlapping the pipeline, and flushes at random times.
 *
 * Tags are allocated the way the ROB does it: only a tag nothing in flight holds, and after a flush the freed tags are
 * reused at once. Flushes come only in the first half of the run. A per-tag scoreboard then catches:
 *  - a writeback in a flush cycle, or for a tag with nothing in flight (a killed op written back after its flush, or
 *    one written twice);
 *  - a result that never comes (a divide that loses the port to the pipeline and is dropped): an op still in flight
 *    after MAX_AGE cycles, or at the end;
 *  - a wrong value or flags;
 *  - a divide or square root taken while o_ds_free is low.
 *
 *     +SEED=<n> +CYCLES=<n> +FLUSH=<per mille> +VEC=<file>
 */
module qv_exu_fpu_tb;
    import qv_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    logic flush = 1'b0;

    fpu_req_t req;
    wb_fp_t   wb;
    logic     ds_free;
    qv_exu_fpu dut (.clk(clk), .rst(rst), .i_flush(flush), .i_req(req), .o_ds_free(ds_free), .o_wb(wb));

    logic [31:0] insn;
    logic [2:0]  frm;
    logic        d_is_fp, d_illegal, d_fmt;
    qv_fp_op_e   d_op;
    logic [1:0]  d_ityp;
    logic [2:0]  d_rm;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        d_ld, d_st, d_r1u, d_r1f, d_r2u, d_r2f, d_r3u, d_rdw, d_rdf;
    logic [1:0]  d_msz;
    logic [63:0] d_imm;
    /* verilator lint_on UNUSEDSIGNAL */
    qv_fp_dec dec0 (
        .i_instr(insn), .i_fs(2'b11), .i_frm(frm),
        .o_is_fp(d_is_fp), .o_illegal(d_illegal), .o_op(d_op), .o_fmt(d_fmt), .o_ityp(d_ityp), .o_rm(d_rm),
        .o_is_load(d_ld), .o_is_store(d_st), .o_mem_size(d_msz), .o_imm(d_imm),
        .o_rs1_used(d_r1u), .o_rs1_fp(d_r1f), .o_rs2_used(d_r2u), .o_rs2_fp(d_r2f), .o_rs3_used(d_r3u),
        .o_rd_wen(d_rdw), .o_rd_fp(d_rdf)
    );

    // the vectors, split by kind
    localparam int MAXV = 20000;
    logic [31:0] v_insn [0:MAXV-1];
    logic [3:0]  v_frm  [0:MAXV-1];
    logic [63:0] v_a [0:MAXV-1];
    logic [63:0] v_b [0:MAXV-1];
    logic [63:0] v_c [0:MAXV-1];
    logic [63:0] v_res [0:MAXV-1];
    logic [7:0]  v_fl [0:MAXV-1];
    int          pidx [0:MAXV-1];
    int          didx [0:MAXV-1];
    int          np = 0, nd = 0, nv = 0;

    // the scoreboard, by tag
    logic        alive [0:15];
    logic [63:0] e_res [0:15];
    logic [4:0]  e_fl  [0:15];
    int          e_vec [0:15];
    int pass_count = 0, fail_count = 0, n_flush = 0, n_ds = 0, n_pipe = 0, n_killed = 0;

    task automatic fail(string msg);
        fail_count++;
        if (fail_count <= 20) $display("FAIL: %s", msg);
    endtask

    // an op in flight longer than this was lost (a divide takes about 60 cycles and then waits for a free port cycle;
    // the stream leaves one at least every few cycles)
    localparam int MAX_AGE = 400;
    int age [0:15];

    always @(posedge clk) begin
        if (!rst && wb.valid && flush) fail($sformatf("a writeback in a flush cycle (tag %0d, t=%0t)", wb.tag, $time));
        for (int t = 0; t < 16; t++)
            if (alive[t]) begin
                age[t] = age[t] + 1;
                if (age[t] == MAX_AGE) fail($sformatf("tag %0d in flight for %0d cycles: lost", t, MAX_AGE));
            end
        if (!rst && wb.valid) begin
            if (!alive[wb.tag]) fail($sformatf("writeback for tag %0d with nothing in flight (t=%0t)", wb.tag, $time));
            else begin
                if (wb.value !== e_res[wb.tag] || wb.flags !== e_fl[wb.tag])
                    fail($sformatf("tag %0d insn %08h: expected %016h/%02h got %016h/%02h", wb.tag,
                                   v_insn[e_vec[wb.tag]], e_res[wb.tag], e_fl[wb.tag], wb.value, wb.flags));
                else pass_count++;
                alive[wb.tag] = 1'b0;
            end
        end
        if (!rst && flush) begin                          // everything in flight is dead
            for (int t = 0; t < 16; t++) if (alive[t]) begin alive[t] = 1'b0; n_killed++; end
        end
    end

    string path;
    int    fd, n, seed, cycles, fpm, k, tag, r;
    logic [31:0] t_insn;
    logic [3:0]  t_frm;
    logic [63:0] t_a, t_b, t_c, t_res;
    logic [7:0]  t_fl;
    logic        found;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path = "../verification/fpu/vectors/smoke.vec";
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("CYCLES=%d", cycles)) cycles = 30000;
        if (!$value$plusargs("FLUSH=%d", fpm)) fpm = 15;
        r = $urandom(seed);
        fd = $fopen(path, "r");
        if (fd == 0) begin
            $display("qv_exu_fpu_tb: cannot open %s", path);
            $display("qv_exu_fpu_tb: FAILURES PRESENT");
            $finish;
        end
        while (!$feof(fd) && nv < MAXV) begin
            n = $fscanf(fd, "%h %h %h %h %h %h %h\n", t_insn, t_frm, t_a, t_b, t_c, t_res, t_fl);
            if (n != 7) break;
            v_insn[nv] = t_insn; v_frm[nv] = t_frm; v_a[nv] = t_a; v_b[nv] = t_b; v_c[nv] = t_c;
            v_res[nv] = t_res; v_fl[nv] = t_fl;
            insn = t_insn; frm = t_frm[2:0]; #1;
            if (d_op == QV_FP_DIV || d_op == QV_FP_SQRT) begin didx[nd] = nv; nd++; end
            else begin pidx[np] = nv; np++; end
            nv++;
        end
        for (int t = 0; t < 16; t++) begin alive[t] = 1'b0; age[t] = 0; end
        req = '0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        for (int cyc = 0; cyc < cycles; cyc++) begin
            @(negedge clk);
            req = '0;
            flush = 1'b0;
            r = $urandom % 1000;
            // flushes only in the first half: in the second a lost result cannot hide behind one
            if (r < fpm && cyc < cycles / 2) begin        // a flush: nothing issues in its cycle
                flush = 1'b1;
                n_flush++;
                continue;
            end
            r = $urandom % 100;
            if (r < 20) continue;                         // idle
            // a free tag, lowest first (after a flush the same tags come back at once)
            found = 1'b0;
            for (int t = 0; t < 16 && !found; t++) if (!alive[t]) begin tag = t; found = 1'b1; end
            if (!found) continue;
            if (r >= 85 && nd > 0) begin                  // a divide or square root, if the side unit is free
                if (!ds_free) continue;
                k = didx[$urandom % nd];
                n_ds++;
            end else begin
                k = pidx[$urandom % np];
                n_pipe++;
            end
            insn = v_insn[k]; frm = v_frm[k][2:0]; #1;
            req.valid = 1'b1; req.tag = tag[QV_ROB_TAG_W-1:0]; req.op = d_op; req.fmt = d_fmt; req.ityp = d_ityp;
            req.rm = d_rm; req.a = v_a[k]; req.b = v_b[k]; req.c = v_c[k];
            alive[tag] = 1'b1; e_res[tag] = v_res[k]; e_fl[tag] = v_fl[k][4:0]; e_vec[tag] = k; age[tag] = 0;
        end
        @(negedge clk) begin req = '0; flush = 1'b0; end
        repeat (200) @(negedge clk);
        for (int t = 0; t < 16; t++) if (alive[t]) fail($sformatf("tag %0d never written back", t));
        $display("");
        $display("qv_exu_fpu_tb: %0d pipeline and %0d divide/sqrt ops, %0d flushes killing %0d", n_pipe, n_ds,
                 n_flush, n_killed);
        $display("qv_exu_fpu_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_exu_fpu_tb: FAILURES PRESENT");
        $finish;
    end

    // a divide or square root presented while the side unit is busy would be lost
    always @(posedge clk)
        if (!rst && req.valid && (req.op == QV_FP_DIV || req.op == QV_FP_SQRT) && !ds_free)
            fail("a divide presented while o_ds_free is low");
endmodule
