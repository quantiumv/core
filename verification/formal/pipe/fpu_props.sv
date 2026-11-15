// SPDX-License-Identifier: MIT

/*
 * fpu_props -- SymbiYosys properties for design/pipe/qv_exu_fpu.sv (its pipeline and its divide/sqrt unit), built
 * with QV_FORMAL_FPU_ABSTRACT: every control path is the real one, the values and flags are free (their arithmetic is
 * checked against TestFloat and Sail vectors instead, qv_fpu_vec_tb).
 *
 * The environment is issue and the ROB: no request in a flush cycle; a divide or square root only while o_ds_free; a
 * request's tag is not held by anything still in flight (the ROB allocates a tag only once it is free). A ghost copy of
 * the pipeline's four stages (valid, tag) and of the one divide in flight says what is in flight.
 *
 * Properties:
 *   - nothing is written back in a flush cycle;
 *   - a pipeline op is written back exactly 4 cycles after its request, unless a flush comes first;
 *   - a writeback that is not the pipeline's is the divide's, for the divide in flight (so every writeback belongs to
 *     exactly one live op, and a killed op is never written back, even when its tag is reused at once);
 *   - o_ds_free is low exactly while a divide is in flight;
 *   - a finished divide is written back in the first cycle the pipeline leaves the port free.
 * (O3) A kill (i_kill_vec, free; never with a flush, never naming the request of its cycle) drops what it names: a
 * pipeline stage holding a killed tag goes no further and is never written back, a killed divide stops (o_ds_free
 * again) and its result is never written back; the rest goes on as before.
 */
module fpu_props (
    input logic        clk,
    input logic        rst,
    input logic        flush,
    input logic        v,
    input logic [3:0]  tag,
    input logic [4:0]  op,
    input logic        fmt,
    input logic [1:0]  ityp,
    input logic [2:0]  rm,
    input logic [15:0] kv
);
    // (O7) this proof is sized for the 4-bit tags of an 8-entry package: every build of it pins QV_ROB_MAX at 8
    if (qv_pkg::QV_ROB_DEPTH != 8) begin : g_rob_pin
        $error("%m: built with qv_pkg::QV_ROB_DEPTH %0d: pin -D QV_ROB_MAX=8", qv_pkg::QV_ROB_DEPTH);
    end
    import qv_pkg::*;

    fpu_req_t req;
    wb_fp_t   wb;
    logic     ds_free;
    always_comb begin
        req       = '0;
        req.valid = v;
        req.tag   = tag;
        req.op    = qv_fp_op_e'(op);
        req.fmt   = fmt;
        req.ityp  = ityp;
        req.rm    = rm;
    end

    qv_exu_fpu dut (.clk(clk), .rst(rst), .i_flush(flush), .i_req(req), .i_kill_vec(kv), .o_ds_free(ds_free),
                    .o_wb(wb));

    wire is_ds = (op == 5'(QV_FP_DIV)) || (op == 5'(QV_FP_SQRT));

    // ---------------- ghost: what is in flight ----------------
    reg        init = 1'b1;
    reg  [3:0] gp_v = 4'b0;
    reg  [3:0] gp_t [0:3];
    reg        gd_v = 1'b0;
    reg  [3:0] gd_t = 4'b0;
    // the pipeline's last stage holds a live op (a killed one leaves the port free); the divide's writeback otherwise
    wire       p3_live = gp_v[3] && !kv[gp_t[3]];
    wire       ds_wb = wb.valid && !p3_live;
    always @(posedge clk) begin
        init <= 1'b0;
        if (rst || flush) begin
            gp_v <= 4'b0;
            gd_v <= 1'b0;
        end else begin
            gp_v    <= {gp_v[2] && !kv[gp_t[2]], gp_v[1] && !kv[gp_t[1]], gp_v[0] && !kv[gp_t[0]], v && !is_ds};
            gp_t[0] <= tag;
            gp_t[1] <= gp_t[0];
            gp_t[2] <= gp_t[1];
            gp_t[3] <= gp_t[2];
            if (v && is_ds) begin
                gd_v <= 1'b1;
                gd_t <= tag;
            end else if (ds_wb || (gd_v && kv[gd_t])) begin
                gd_v <= 1'b0;
            end
        end
    end

    function automatic logic held(input logic [3:0] t);
        held = (gp_v[0] && gp_t[0] == t) || (gp_v[1] && gp_t[1] == t) || (gp_v[2] && gp_t[2] == t) ||
               (gp_v[3] && gp_t[3] == t) || (gd_v && gd_t == t);
    endfunction

    // the tags a flush killed (for a cover below)
    reg [15:0] killed = 16'b0;
    always @(posedge clk) begin
        for (int t = 0; t < 16; t++) killed[t] <= flush && held(4'(t));
    end

    // ---------------- environment ----------------
    always @* begin
        if (init) assume (rst);
        assume (op <= 5'(QV_FP_F2F));
        if (flush) assume (!v);
        if (v && is_ds) assume (ds_free);
        if (v) assume (!held(tag));
        if (kv != 16'b0) assume (!flush);
        if (v) assume (!kv[tag]);
    end

    // ---------------- properties ----------------
    always @* if (!init && !rst) begin
        if (flush) assert (!wb.valid);
        if (gp_v[3] && !flush && !kv[gp_t[3]]) assert (wb.valid && wb.tag == gp_t[3]);
        if (wb.valid) assert (!kv[wb.tag]);                              // (O3) nothing killed is written back
        if (wb.valid && !p3_live) assert (gd_v && wb.tag == gd_t);
        assert (ds_free == !gd_v);
        if (dut.ds_done && !p3_live && !flush && !kv[gd_t]) assert (wb.valid && wb.tag == gd_t);
    end

    // ---------------- lemmas for the induction ----------------
    always @* if (!init && !rst) begin
        assert (dut.pipe0.r0.valid == gp_v[0]);
        assert (dut.pipe0.r1_valid == gp_v[1]);
        assert (dut.pipe0.r2_valid == gp_v[2]);
        assert (dut.pipe0.r3_valid == gp_v[3]);
        if (gp_v[0]) assert (dut.pipe0.r0.tag == gp_t[0]);
        if (gp_v[1]) assert (dut.pipe0.r1_tag == gp_t[1]);
        if (gp_v[2]) assert (dut.pipe0.r2_tag == gp_t[2]);
        if (gp_v[3]) assert (dut.pipe0.r3_tag == gp_t[3]);
        if (gd_v) assert (dut.ds0.tag_q == gd_t);
        if (dut.ds0.st_q == 3'd2) assert (dut.ds0.cnt_q != 6'd0 && dut.ds0.cnt_q <= 6'd3);   // S_ITER
        assert (dut.ds0.st_q <= 3'd4);
    end

    // ---------------- covers ----------------
    always @* if (!init && !rst) begin
        cover (ds_wb);                                     // a divide written back
        cover (dut.ds_done && gp_v[3]);                    // a finished divide waits for the pipeline
        cover (flush && gd_v && gp_v != 4'b0);             // a flush kills ops in both units
        cover (gp_v == 4'b1111);                           // the pipeline full
        cover (v && killed[tag]);                          // a tag a flush killed, reused in the next cycle
        cover (gd_v && kv[gd_t] && gp_v[1] && !kv[gp_t[1]]); // (O3) a kill of the divide that a pipeline op survives
        cover (gp_v[2] && kv[gp_t[2]] && gp_v[0]);         // (O3) a pipeline op killed between two others
    end
endmodule
