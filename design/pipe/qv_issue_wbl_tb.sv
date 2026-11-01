// SPDX-License-Identifier: MIT

/*
 * qv_issue_wbl_tb -- design/pipe/qv_issue.sv's bypass from the LSU's writeback (LSU_BYPASS, O2d), on its own.
 *
 * A load claims its destination (x5 for an integer load, f7 for an FP one); an op that reads it then waits, and with
 * LSU_BYPASS (and BYPASS_EN) issues in the very cycle the LSU's writeback carries the load's tag, with that value as
 * its operand: rs1, rs2 and an FMA's rs3. A writeback of another tag, or of its tag but not valid, does not release it. Without LSU_BYPASS (or
 * without BYPASS_EN) it waits for the value in the ROB, the cycle after.
 */
module qv_issue_wbl_tb #(
    parameter bit LSU_BYPASS = 1'b1,
    parameter bit BYPASS_EN  = 1'b1
);
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic                    uop_valid = 1'b0, issue;
    uop_t                    uop = '0;
    logic [QV_ROB_TAG_W-1:0] alloc_tag = '0, l1_tag, l2_tag, l3_tag;
    logic                    l_complete = 1'b0;      // every lookup: complete with l_value
    logic [63:0]             l_value = '0;
    wb_t                     wbl = '0;
    fu_req_t                 alu_req, lsu_req;
    fpu_req_t                fpu_req;

    /* verilator lint_off PINCONNECTEMPTY */
    qv_issue #(.BYPASS_EN(BYPASS_EN), .LSU_BYPASS(LSU_BYPASS)) dut (
        .clk(clk), .rst(rst), .i_flush(1'b0),
        .i_uop_valid(uop_valid), .i_uop(uop), .o_issue(issue),
        .o_rs1_sel(), .o_rs2_sel(), .i_rs1_data(64'h0), .i_rs2_data(64'h0),
        .o_alloc_valid(), .o_alloc_pc(), .o_alloc_raw(), .o_alloc_rd(), .o_alloc_rd_wen(), .o_alloc_next_pc(),
        .o_alloc_shadow(), .o_alloc_ctrl(),
        .i_alloc_tag(alloc_tag), .i_alloc_ready(1'b1), .i_rob_empty(1'b0),
        .o_lookup1_tag(l1_tag), .i_lookup1_complete(l_complete), .i_lookup1_value(l_value),
        .o_lookup2_tag(l2_tag), .i_lookup2_complete(l_complete), .i_lookup2_value(l_value),
        .o_lookup3_tag(l3_tag), .i_lookup3_complete(l_complete), .i_lookup3_value(l_value),
        .o_frs1_sel(), .o_frs2_sel(), .o_frs3_sel(),
        .i_wbl(wbl), .o_fpu_req(fpu_req),
        .i_wb('0), .o_alu_req(alu_req), .o_bru_req(), .o_lsu_req(lsu_req), .i_lsu_free(1'b1),
        .o_div_req(), .i_div_free(1'b1),
        .i_commit_valid(1'b0), .i_commit_rd(5'd0), .i_commit_rd_wen(1'b0), .i_commit_tag('0)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // issue a load to x5 (fp: to f7) with tag t
    task automatic issue_load(input logic fp, input logic [QV_ROB_TAG_W-1:0] t);
        @(negedge clk);
        uop = '0; uop.fu = QV_FU_LSU; uop.is_load = 1'b1; uop.mem_size = 2'd3;
        uop.rd = fp ? 5'd7 : 5'd5; uop.rd_wen = 1'b1; uop.rd_fp = fp;
        alloc_tag = t; uop_valid = 1'b1;
        #1;
        check("the load issues", b(issue), 64'd1);
        @(posedge clk); #1;
        uop_valid = 1'b0;
    endtask

    // present an op that reads the load's register (which: 1 rs1, 2 rs2, 3 an FMA's rs3), with tag t
    task automatic present_reader(input int which, input logic [QV_ROB_TAG_W-1:0] t);
        @(negedge clk);
        uop = '0; alloc_tag = t;
        if (which == 3) begin
            uop.fu = QV_FU_FPU; uop.rs3 = 5'd7; uop.rs3_used = 1'b1; uop.rd = 5'd8; uop.rd_wen = 1'b1; uop.rd_fp = 1'b1;
        end else begin
            uop.fu = QV_FU_ALU; uop.rd = 5'd6; uop.rd_wen = 1'b1;
            if (which == 1) begin uop.rs1 = 5'd5; uop.rs1_used = 1'b1; end
            else            begin uop.rs2 = 5'd5; uop.rs2_used = 1'b1; end
        end
        uop_valid = 1'b1;
    endtask

    task automatic case_one(input int which, input logic [QV_ROB_TAG_W-1:0] tl, input logic [QV_ROB_TAG_W-1:0] tr,
                            input logic [63:0] v);
        logic [63:0] got;
        issue_load(which == 3, tl);
        present_reader(which, tr);
        #1;
        check($sformatf("reader %0d: waits for the load", which), b(issue), 64'd0);
        // another tag's writeback does not release it
        wbl = '0; wbl.valid = 1'b1; wbl.tag = tl + 4'd3; wbl.value = ~v;
        #1;
        check($sformatf("reader %0d: another tag's writeback: still waits", which), b(issue), 64'd0);
        // the load's tag on the bus but not valid does not either
        wbl.valid = 1'b0; wbl.tag = tl; wbl.value = ~v;
        #1;
        check($sformatf("reader %0d: its tag, not valid: still waits", which), b(issue), 64'd0);
        wbl.valid = 1'b1; wbl.tag = tl + 4'd3;
        @(posedge clk); #1;
        // the load's own writeback
        wbl.tag = tl; wbl.value = v;
        #1;
        got = (which == 1) ? alu_req.a : (which == 2) ? alu_req.b : fpu_req.c;
        if (LSU_BYPASS && BYPASS_EN) begin
            check($sformatf("reader %0d: issues in the load's writeback cycle", which), b(issue), 64'd1);
            check($sformatf("reader %0d: with the load's value", which), got, v);
        end else begin
            check($sformatf("reader %0d: without the bypass, not in the writeback cycle", which), b(issue), 64'd0);
        end
        @(posedge clk); #1;
        wbl = '0;
        if (!(LSU_BYPASS && BYPASS_EN)) begin
            // the ROB has it from the next cycle
            l_complete = 1'b1; l_value = v; #1;
            check($sformatf("reader %0d: issues from the ROB the cycle after", which), b(issue), 64'd1);
            got = (which == 1) ? alu_req.a : (which == 2) ? alu_req.b : fpu_req.c;
            check($sformatf("reader %0d: with the ROB's value", which), got, v);
            @(posedge clk); #1;
            l_complete = 1'b0;
        end
        uop_valid = 1'b0;
        // drop the claims: a reset is the simplest way here
        rst = 1'b1; @(posedge clk); #1; rst = 1'b0;
    endtask

    initial begin
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        case_one(1, 4'd2, 4'd3, 64'h1111_2222_3333_4444);
        case_one(2, 4'd5, 4'd6, 64'h5555_6666_7777_8888);
        case_one(3, 4'd9, 4'd10, 64'h3FF0_0000_0000_0000);
        $display("");
        $display("qv_issue_wbl_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_issue_wbl_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #100_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
