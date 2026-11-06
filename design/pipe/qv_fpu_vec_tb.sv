// SPDX-License-Identifier: MIT

/*
 * qv_fpu_vec_tb -- the FPU datapath against architectural vectors (verification/fpu/gen_vectors.py: TestFloat cases and
 * the golden model's, checked against Sail).
 *
 * Each vector is an instruction, frm, the three source register values, the expected rd value and flags. The
 * instruction goes through qv_fp_dec (FS Dirty, the vector's frm), so decode's op/fmt/rounding-mode mapping is under
 * test too. Pipeline ops are sent one per cycle into qv_fpu_pipe and checked in order as they come out; a divide or
 * square root waits for the pipeline to drain and runs alone on qv_fpu_divsqrt.
 *
 *     +VEC=<file>   the vectors (default ../verification/fpu/vectors/smoke.vec, the regression's: 10,483 cases, every
 *                   op, precision and rounding mode, checked against Sail; the run directory is design/)
 *     +MAX=<n>      stop after n vectors
 */
module qv_fpu_vec_tb;
    import qv_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    fpu_req_t preq, dreq;
    wb_fp_t   pwb, dres;
    logic     dbusy, ddone, dack;

    qv_fpu_pipe pipe0 (.clk(clk), .rst(rst), .i_flush(1'b0), .i_req(preq), .o_wb(pwb));
    qv_fpu_divsqrt ds0 (.clk(clk), .rst(rst), .i_flush(1'b0), .i_req(dreq), .o_busy(dbusy), .o_done(ddone),
                        .o_res(dres), .i_ack(dack));

    logic [31:0] insn;
    logic [2:0]  frm;
    logic        d_is_fp, d_illegal, d_fmt, d_ld, d_st;
    qv_fp_op_e   d_op;
    logic [1:0]  d_ityp, d_msz;
    logic [2:0]  d_rm;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] d_imm;
    logic        d_r1u, d_r1f, d_r2u, d_r2f, d_r3u, d_rdw, d_rdf;
    /* verilator lint_on UNUSEDSIGNAL */
    qv_fp_dec dec0 (
        .i_instr(insn), .i_fs(2'b11), .i_frm(frm),
        .o_is_fp(d_is_fp), .o_illegal(d_illegal), .o_op(d_op), .o_fmt(d_fmt), .o_ityp(d_ityp), .o_rm(d_rm),
        .o_is_load(d_ld), .o_is_store(d_st), .o_mem_size(d_msz), .o_imm(d_imm),
        .o_rs1_used(d_r1u), .o_rs1_fp(d_r1f), .o_rs2_used(d_r2u), .o_rs2_fp(d_r2f), .o_rs3_used(d_r3u),
        .o_rd_wen(d_rdw), .o_rd_fp(d_rdf)
    );

    // expected results of the ops in the pipeline, by tag
    logic [63:0] exp_res [0:15];
    logic [4:0]  exp_fl  [0:15];
    logic [31:0] exp_insn [0:15];
    logic [63:0] exp_a [0:15];
    logic [63:0] exp_b [0:15];
    logic [63:0] exp_c [0:15];
    int outstanding = 0;
    int pass_count = 0, fail_count = 0;

    task automatic report(string what, logic [31:0] i, logic [63:0] a, logic [63:0] b, logic [63:0] c,
                          logic [63:0] er, logic [4:0] ef, logic [63:0] gr, logic [4:0] gf);
        if (gr === er && gf === ef) begin
            pass_count++;
        end else begin
            fail_count++;
            if (fail_count <= 30)
                $display("FAIL %s insn=%08h a=%016h b=%016h c=%016h expect=%016h/%02h got=%016h/%02h",
                         what, i, a, b, c, er, ef, gr, gf);
        end
    endtask

    always @(posedge clk) begin
        if (pwb.valid) begin
            report("pipe", exp_insn[pwb.tag], exp_a[pwb.tag], exp_b[pwb.tag], exp_c[pwb.tag],
                   exp_res[pwb.tag], exp_fl[pwb.tag], pwb.value, pwb.flags);
            outstanding = outstanding - 1;
        end
    end

    string       path;
    int          fd, n, maxn, cnt;
    logic [31:0] v_insn;
    logic [3:0]  v_frm;
    logic [63:0] v_a, v_b, v_c, v_res;
    logic [7:0]  v_fl;
    logic [3:0]  wtag;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path = "../verification/fpu/vectors/smoke.vec";
        if (!$value$plusargs("MAX=%d", maxn)) maxn = 0;
        fd = $fopen(path, "r");
        if (fd == 0) begin
            $display("qv_fpu_vec_tb: cannot open %s", path);
            $display("qv_fpu_vec_tb: FAILURES PRESENT");
            $finish;
        end
        preq = '0; dreq = '0; dack = 1'b0; insn = '0; frm = '0; wtag = '0; cnt = 0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 1'b0;
        while (!$feof(fd) && (maxn == 0 || cnt < maxn)) begin
            n = $fscanf(fd, "%h %h %h %h %h %h %h\n", v_insn, v_frm, v_a, v_b, v_c, v_res, v_fl);
            if (n != 7) break;
            cnt++;
            insn = v_insn;
            frm  = v_frm[2:0];
            #1;
            if (!d_is_fp || d_illegal || d_ld || d_st) begin
                fail_count++;
                $display("FAIL decode insn=%08h is_fp=%b illegal=%b", v_insn, d_is_fp, d_illegal);
                continue;
            end
            if (d_op == QV_FP_DIV || d_op == QV_FP_SQRT) begin
                @(negedge clk) preq.valid = 1'b0;
                while (outstanding != 0) @(negedge clk);
                dreq = '0;
                dreq.valid = 1'b1; dreq.op = d_op; dreq.fmt = d_fmt; dreq.rm = d_rm;
                dreq.a = v_a; dreq.b = v_b; dreq.c = v_c;
                @(negedge clk) dreq.valid = 1'b0;
                while (!ddone) @(negedge clk);
                report("divsqrt", v_insn, v_a, v_b, v_c, v_res, v_fl[4:0], dres.value, dres.flags);
                dack = 1'b1;
                @(negedge clk) dack = 1'b0;
            end else begin
                @(negedge clk);
                exp_res[wtag] = v_res; exp_fl[wtag] = v_fl[4:0]; exp_insn[wtag] = v_insn;
                exp_a[wtag] = v_a; exp_b[wtag] = v_b; exp_c[wtag] = v_c;
                preq = '0;
                preq.valid = 1'b1; preq.tag = wtag; preq.op = d_op; preq.fmt = d_fmt; preq.ityp = d_ityp;
                preq.rm = d_rm; preq.a = v_a; preq.b = v_b; preq.c = v_c;
                outstanding = outstanding + 1;
                wtag = wtag + 4'd1;
            end
        end
        @(negedge clk) preq.valid = 1'b0;
        while (outstanding != 0) @(negedge clk);
        $display("");
        $display("qv_fpu_vec_tb: %0d vectors from %s", cnt, path);
        $display("qv_fpu_vec_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_fpu_vec_tb: FAILURES PRESENT");
        $finish;
    end
endmodule
