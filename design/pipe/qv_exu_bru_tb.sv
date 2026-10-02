// SPDX-License-Identifier: MIT

/*
 * qv_exu_bru_tb -- standalone test for design/pipe/qv_exu_bru.sv.
 *
 * Every op against a golden model, directed edge cases first (signed vs
 * unsigned compares at the sign boundary, equal operands, negative
 * offsets, a taken branch to the next instruction, JALR with an odd sum,
 * RVC fall-through), then random operands. Also: the one-cycle latency,
 * tag passthrough, no writeback (and so no mispredict) without a valid
 * request, and flush killing a request in flight.
 */
module qv_exu_bru_tb;
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic    flush = 1'b0;
    fu_req_t req = '0;
    wb_t     wb;

    qv_exu_bru dut (.clk(clk), .rst(rst), .i_flush(flush), .i_req(req), .o_wb(wb));

    function automatic logic golden_taken(input qv_bru_op_e op, input logic [63:0] a, input logic [63:0] b);
        case (op)
            QV_BR_BEQ:  return a == b;
            QV_BR_BNE:  return a != b;
            QV_BR_BLT:  return $signed(a) <  $signed(b);
            QV_BR_BGE:  return $signed(a) >= $signed(b);
            QV_BR_BLTU: return a <  b;
            QV_BR_BGEU: return a >= b;
            default:    return 1'b1;
        endcase
    endfunction

    function automatic string op_name(input qv_bru_op_e op);
        case (op)
            QV_BR_BEQ:  return "BEQ";
            QV_BR_BNE:  return "BNE";
            QV_BR_BLT:  return "BLT";
            QV_BR_BGE:  return "BGE";
            QV_BR_BLTU: return "BLTU";
            QV_BR_BGEU: return "BGEU";
            QV_BR_JAL:  return "JAL";
            default:    return "JALR";
        endcase
    endfunction

    int n_req = 0;

    // present one request, check the writeback the following cycle
    task automatic run(input string name, input qv_bru_op_e op, input logic [63:0] a, input logic [63:0] b,
                       input logic [63:0] pc, input logic [63:0] imm, input logic rvc = 1'b0);
        logic [63:0] ft, tgt, nxt;
        logic [QV_ROB_TAG_W-1:0] tag;
        tag = QV_ROB_TAG_W'(n_req++);
        ft  = pc + (rvc ? 64'd2 : 64'd4);
        tgt = (op == QV_BR_JALR) ? ((a + b) & ~64'd1) : pc + imm;
        nxt = golden_taken(op, a, b) ? tgt : ft;
        repeat (2) @(negedge clk);                       // an idle cycle drains the previous request
        req       = '0;
        req.valid = 1'b1;
        req.tag   = tag;
        req.op    = 5'(op);
        req.a     = a;
        req.b     = b;
        req.pc    = pc;
        req.imm   = imm;
        req.rvc   = rvc;
        #1;
        check({name, ": no writeback in the issue cycle"}, {63'b0, wb.valid}, 64'd0);
        @(posedge clk); #1;
        req = '0;
        check({name, ": valid"}, {63'b0, wb.valid}, 64'd1);
        check({name, ": tag"}, {60'b0, wb.tag}, {60'b0, tag});
        check({name, ": link"}, wb.value, ft);
        check({name, ": next_pc"}, wb.next_pc, nxt);
        check({name, ": mispredict"}, {63'b0, wb.mispredict}, {63'b0, nxt != ft});
    endtask

    localparam logic [63:0] MIN = 64'h8000_0000_0000_0000, MAX = 64'h7FFF_FFFF_FFFF_FFFF;
    localparam logic [63:0] PC  = 64'h0000_0000_0000_1000;

    qv_bru_op_e ops [0:7] = '{QV_BR_BEQ, QV_BR_BNE, QV_BR_BLT, QV_BR_BGE,
                               QV_BR_BLTU, QV_BR_BGEU, QV_BR_JAL, QV_BR_JALR};

    initial begin
        repeat (2) @(posedge clk);
        #1 rst = 1'b0;
        #1;
        check("reset: no writeback", {63'b0, wb.valid}, 64'd0);
        check("reset: no mispredict", {63'b0, wb.mispredict}, 64'd0);

        // ---- conditional branches at the boundaries that tell the ops apart ----
        for (int k = 0; k < 6; k++) begin
            run({op_name(ops[k]), " equal"}, ops[k], 64'd5, 64'd5, PC, 64'd64);
            run({op_name(ops[k]), " MIN vs 1"}, ops[k], MIN, 64'd1, PC, 64'd64);   // signed <, unsigned >
            run({op_name(ops[k]), " 1 vs MIN"}, ops[k], 64'd1, MIN, PC, 64'd64);
            run({op_name(ops[k]), " -1 vs MAX"}, ops[k], '1, MAX, PC, -64'd32);    // backward target
            run({op_name(ops[k]), " 0 vs -1"}, ops[k], 64'd0, '1, PC, -64'd4096);
        end
        // taken, but to the next instruction: not a mispredict
        run("BEQ taken to pc+4", QV_BR_BEQ, 64'd7, 64'd7, PC, 64'd4);
        // not taken: falls through, never a mispredict
        run("BNE not taken", QV_BR_BNE, 64'd7, 64'd7, PC, 64'd64);

        // ---- JAL ----
        run("JAL forward", QV_BR_JAL, 64'hDEAD, 64'd0, PC, 64'd2048);
        run("JAL backward", QV_BR_JAL, 64'd0, 64'd0, PC, -64'd8);
        run("JAL to pc+4", QV_BR_JAL, 64'd0, 64'd0, PC, 64'd4);
        run("JAL to self", QV_BR_JAL, 64'd0, 64'd0, PC, 64'd0);

        // ---- JALR: (rs1 + offset), bit 0 cleared ----
        run("JALR even", QV_BR_JALR, 64'h2000, 64'd16, PC, 64'd999);       // imm unused
        run("JALR odd sum", QV_BR_JALR, 64'h2001, 64'd16, PC, 64'd0);
        run("JALR odd offset", QV_BR_JALR, 64'h2000, 64'd17, PC, 64'd0);
        run("JALR negative offset", QV_BR_JALR, 64'h2000, -64'd2047, PC, 64'd0);
        run("JALR to pc+4", QV_BR_JALR, PC, 64'd4, PC, 64'd0);
        run("JALR wraps", QV_BR_JALR, '1, 64'd3, PC, 64'd0);

        // ---- RVC fall-through (pc + 2) ----
        run("BNE not taken rvc", QV_BR_BNE, 64'd1, 64'd1, PC, 64'd64, 1'b1);
        run("BEQ taken to pc+2 rvc", QV_BR_BEQ, 64'd1, 64'd1, PC, 64'd2, 1'b1);
        run("JAL rvc link", QV_BR_JAL, 64'd0, 64'd0, PC, 64'd100, 1'b1);

        // ---- random ----
        for (int i = 0; i < 2000; i++) begin
            logic [63:0] a, b, imm;
            a   = {$urandom, $urandom};
            b   = ($urandom % 4 == 0) ? a : {$urandom, $urandom};
            imm = 64'($signed(13'($urandom)) & ~64'd1);
            run($sformatf("random %0d", i), ops[$urandom % 8], a, b, {$urandom, $urandom}, imm, 1'($urandom));
        end

        // ---- back-to-back requests: each result lands exactly one cycle later ----
        @(negedge clk);
        req = '0; req.valid = 1'b1; req.tag = 1; req.op = 5'(QV_BR_JAL); req.pc = PC; req.imm = 64'd64;
        @(negedge clk);
        check("back-to-back: first result", wb.next_pc, PC + 64'd64);
        req.tag = 2; req.pc = PC + 64'd64; req.imm = 64'd4;
        @(negedge clk);
        check("back-to-back: second result tag", {60'b0, wb.tag}, 64'd2);
        check("back-to-back: second not a mispredict", {63'b0, wb.mispredict}, 64'd0);
        req = '0;

        // ---- flush kills a request in flight ----
        @(negedge clk);
        req = '0; req.valid = 1'b1; req.tag = 3; req.op = 5'(QV_BR_JAL); req.pc = PC; req.imm = 64'd64;
        flush = 1'b1;
        @(posedge clk); #1;
        flush = 1'b0;
        req   = '0;
        check("flush: no writeback", {63'b0, wb.valid}, 64'd0);
        check("flush: no mispredict", {63'b0, wb.mispredict}, 64'd0);

        $display("");
        $display("qv_exu_bru_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_exu_bru_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #1000000;
        $display("TIMEOUT: qv_exu_bru_tb");
        $finish;
    end
endmodule
