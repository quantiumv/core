// SPDX-License-Identifier: MIT

/*
 * ref_exu_fpu -- the FP functional unit: ref_fpu_pipe for every op but divide and square root (4 cycles, one op per
 * cycle, in order) and ref_fpu_divsqrt for those (one at a time, about 60 cycles, held until written back).
 *
 * Issue sends one op per cycle (i_req). A pipeline op is always taken; a divide or square root only while the side
 * unit is free (o_ds_free, registered: issue stalls a second one until the first has written back). Pipeline ops may
 * pass a divide and complete first; the ROB takes results by tag.
 *
 * One writeback port (o_wb, to the ROB and the bypass): the pipeline's result has it whenever there is one; a finished
 * divide waits for a cycle the pipeline does not use and is acknowledged then. That wait is bounded: the divide is older
 * than everything competing for the port, the pipeline never stalls, and the ROB's depth limits how much can be issued
 * past it. i_flush kills both units; the writeback is masked in a flush cycle, so nothing written back belongs to a tag
 * that a flush has freed (qv_exu_div.sv has the same rule).
 *
 * QV_FORMAL_FPU_ABSTRACT (the riscv-formal pipe-fpu model and fpu_props.sv) keeps every control path and replaces the
 * datapath values with free ones; see ref_fpu_pipe.sv and ref_fpu_divsqrt.sv.
 */
module ref_exu_fpu (
    input  logic             clk,
    input  logic             rst,
    input  logic             i_flush,
    input  ref_fpu_pkg::fpu_req_t i_req,
    output logic             o_ds_free,    // a divide or square root would be taken now
    output ref_fpu_pkg::wb_fp_t   o_wb
);
    import ref_fpu_pkg::*;

    wire is_ds = i_req.op == QV_FP_DIV || i_req.op == QV_FP_SQRT;

    fpu_req_t preq, dreq;
    always_comb begin
        preq       = i_req;
        preq.valid = i_req.valid && !is_ds;
        dreq       = i_req;
        dreq.valid = i_req.valid && is_ds;
    end

    wb_fp_t pwb, dres;
    logic   ds_busy, ds_done, ds_ack;

    ref_fpu_pipe pipe0 (.clk(clk), .rst(rst), .i_flush(i_flush), .i_req(preq), .o_wb(pwb));
    ref_fpu_divsqrt ds0 (.clk(clk), .rst(rst), .i_flush(i_flush), .i_req(dreq), .o_busy(ds_busy), .o_done(ds_done),
                        .o_res(dres), .i_ack(ds_ack));

    assign o_ds_free = !ds_busy;
    assign ds_ack    = ds_done && !pwb.valid && !i_flush;
    always_comb begin
        o_wb = pwb.valid ? pwb : dres;
        o_wb.valid = (pwb.valid || ds_done) && !i_flush;
    end
endmodule
