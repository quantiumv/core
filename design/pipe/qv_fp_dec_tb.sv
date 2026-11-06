// SPDX-License-Identifier: MIT

/*
 * qv_fp_dec_tb -- qv_fp_dec's classification and legality, case by case. The legality cases are the ones probed on
 * Sail (verification/fpu/README.md, probes 40-55 and 80-86): FS Off, reserved rounding modes (also on the exact
 * conversions), reserved fmt (H, Q), reserved funct3 and rs2 fields, LOAD-FP/STORE-FP widths other than W and D.
 * The mapping cases check op, fmt, ityp, the resolved rounding mode and the operand classes of each instruction kind.
 * (The datapath behind decode is qv_fpu_vec_tb's.)
 */
module qv_fp_dec_tb;
    import qv_pkg::*;

    logic [31:0] insn;
    logic [1:0]  fs;
    logic [2:0]  frm;
    logic        is_fp, illegal, fmt, ld, st, r1u, r1f, r2u, r2f, r3u, rdw, rdf;
    qv_fp_op_e   op;
    logic [1:0]  ityp, msz;
    logic [2:0]  rm;
    logic [63:0] imm;

    qv_fp_dec dut (
        .i_instr(insn), .i_fs(fs), .i_frm(frm),
        .o_is_fp(is_fp), .o_illegal(illegal), .o_op(op), .o_fmt(fmt), .o_ityp(ityp), .o_rm(rm),
        .o_is_load(ld), .o_is_store(st), .o_mem_size(msz), .o_imm(imm),
        .o_rs1_used(r1u), .o_rs1_fp(r1f), .o_rs2_used(r2u), .o_rs2_fp(r2f), .o_rs3_used(r3u),
        .o_rd_wen(rdw), .o_rd_fp(rdf)
    );

    int pass_count = 0, fail_count = 0;
    task automatic check(string name, logic [63:0] got, logic [63:0] exp);
        if (got === exp) pass_count++;
        else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, exp, got);
        end
    endtask

    // R-type OP-FP and R4 encodings (rd 4, rs1 1, rs2 2, rs3 3 unless given)
    function automatic logic [31:0] opfp(input logic [4:0] f5, input logic [1:0] fm, input logic [4:0] rs2,
                                         input logic [2:0] f3);
        return {f5, fm, rs2, 5'd1, f3, 5'd4, 7'b1010011};
    endfunction
    function automatic logic [31:0] r4(input logic [6:0] opc, input logic [1:0] fm, input logic [2:0] f3);
        return {5'd3, fm, 5'd2, 5'd1, f3, 5'd4, opc};
    endfunction

    task automatic legal(string name, logic [31:0] i, logic [2:0] f, logic exp_ill);
        insn = i; frm = f; #1;
        check({name, ": is_fp"}, is_fp, 1'b1);
        check({name, ": illegal"}, illegal, exp_ill);
    endtask

    initial begin
        fs = 2'b11; frm = 3'd0;

        // ---- legality (FS on) ----
        legal("fadd.d rne",              opfp(5'b00000, 2'b01, 5'd2, 3'd0), 3'd0, 1'b0);
        legal("fadd.d rm 5",             opfp(5'b00000, 2'b01, 5'd2, 3'd5), 3'd0, 1'b1);
        legal("fadd.d rm 6",             opfp(5'b00000, 2'b01, 5'd2, 3'd6), 3'd0, 1'b1);
        legal("fadd.d dyn, frm 4",       opfp(5'b00000, 2'b01, 5'd2, 3'd7), 3'd4, 1'b0);
        legal("fadd.d dyn, frm 5",       opfp(5'b00000, 2'b01, 5'd2, 3'd7), 3'd5, 1'b1);
        legal("fadd.d dyn, frm 7",       opfp(5'b00000, 2'b01, 5'd2, 3'd7), 3'd7, 1'b1);
        legal("fcvt.d.w rm 5 (exact)",   opfp(5'b11010, 2'b01, 5'd0, 3'd5), 3'd0, 1'b1);
        legal("fcvt.d.s rm 5 (exact)",   opfp(5'b01000, 2'b01, 5'd0, 3'd5), 3'd0, 1'b1);
        legal("fcvt.d.w dyn, frm 7",     opfp(5'b11010, 2'b01, 5'd0, 3'd7), 3'd7, 1'b1);
        legal("fsgnj.d funct3 3",        opfp(5'b00100, 2'b01, 5'd2, 3'd3), 3'd0, 1'b1);
        legal("fsgnjx.d funct3 2",       opfp(5'b00100, 2'b01, 5'd2, 3'd2), 3'd0, 1'b0);
        legal("fsgnj ignores frm",       opfp(5'b00100, 2'b01, 5'd2, 3'd0), 3'd7, 1'b0);
        legal("fmv.x.d funct3 2",        opfp(5'b11100, 2'b01, 5'd0, 3'd2), 3'd0, 1'b1);
        legal("fmv.x.d rs2 1",           opfp(5'b11100, 2'b01, 5'd1, 3'd0), 3'd0, 1'b1);
        legal("fclass.d rs2 1",          opfp(5'b11100, 2'b01, 5'd1, 3'd1), 3'd0, 1'b1);
        legal("fmin.d funct3 2",         opfp(5'b00101, 2'b01, 5'd2, 3'd2), 3'd0, 1'b1);
        legal("fmax.s",                  opfp(5'b00101, 2'b00, 5'd2, 3'd1), 3'd0, 1'b0);
        legal("fsqrt.d rs2 1",           opfp(5'b01011, 2'b01, 5'd1, 3'd0), 3'd0, 1'b1);
        legal("fadd.h (fmt 2)",          opfp(5'b00000, 2'b10, 5'd2, 3'd0), 3'd0, 1'b1);
        legal("fadd.q (fmt 3)",          opfp(5'b00000, 2'b11, 5'd2, 3'd0), 3'd0, 1'b1);
        legal("fmadd.q (fmt 3)",         r4(7'b1000011, 2'b11, 3'd0),       3'd0, 1'b1);
        legal("fmadd.d rm 6",            r4(7'b1000011, 2'b01, 3'd6),       3'd0, 1'b1);
        legal("fmv.d.x rs2 1",           opfp(5'b11110, 2'b01, 5'd1, 3'd0), 3'd0, 1'b1);
        legal("fmv.d.x funct3 1",        opfp(5'b11110, 2'b01, 5'd0, 3'd1), 3'd0, 1'b1);
        legal("fcvt.w.d rm 6",           opfp(5'b11000, 2'b01, 5'd0, 3'd6), 3'd0, 1'b1);
        legal("fcvt.w.d rs2 4",          opfp(5'b11000, 2'b01, 5'd4, 3'd0), 3'd0, 1'b1);
        legal("fcvt.d.lu",               opfp(5'b11010, 2'b01, 5'd3, 3'd0), 3'd0, 1'b0);
        legal("feq.d funct3 3",          opfp(5'b10100, 2'b01, 5'd2, 3'd3), 3'd0, 1'b1);
        legal("fcvt.s.d rs2 1",          opfp(5'b01000, 2'b00, 5'd1, 3'd0), 3'd0, 1'b0);
        legal("fcvt.s.d rs2 2",          opfp(5'b01000, 2'b00, 5'd2, 3'd0), 3'd0, 1'b1);
        legal("fcvt.d.s rs2 1",          opfp(5'b01000, 2'b01, 5'd1, 3'd0), 3'd0, 1'b1);
        legal("fclass.d rs2 0",          opfp(5'b11100, 2'b01, 5'd0, 3'd1), 3'd0, 1'b0);
        legal("unused funct5 00110",     opfp(5'b00110, 2'b01, 5'd2, 3'd0), 3'd0, 1'b1);
        legal("flw",                     {12'h010, 5'd1, 3'b010, 5'd4, 7'b0000111}, 3'd0, 1'b0);
        legal("fld",                     {12'h010, 5'd1, 3'b011, 5'd4, 7'b0000111}, 3'd0, 1'b0);
        legal("LOAD-FP width 0 (vector)", {12'h010, 5'd1, 3'b000, 5'd4, 7'b0000111}, 3'd0, 1'b1);
        legal("LOAD-FP width 4 (flq)",   {12'h010, 5'd1, 3'b100, 5'd4, 7'b0000111}, 3'd0, 1'b1);
        legal("STORE-FP width 1 (fsh)",  {7'h0, 5'd2, 5'd1, 3'b001, 5'd4, 7'b0100111}, 3'd0, 1'b1);
        legal("fsd",                     {7'h0, 5'd2, 5'd1, 3'b011, 5'd4, 7'b0100111}, 3'd0, 1'b0);

        // ---- FS Off: every FP instruction is illegal ----
        fs = 2'b00;
        legal("FS off: fadd.d",          opfp(5'b00000, 2'b01, 5'd2, 3'd0), 3'd0, 1'b1);
        legal("FS off: fmv.x.d",         opfp(5'b11100, 2'b01, 5'd0, 3'd0), 3'd0, 1'b1);
        legal("FS off: fld",             {12'h010, 5'd1, 3'b011, 5'd4, 7'b0000111}, 3'd0, 1'b1);
        legal("FS off: fsd",             {7'h0, 5'd2, 5'd1, 3'b011, 5'd4, 7'b0100111}, 3'd0, 1'b1);
        legal("FS off: fmadd.s",         r4(7'b1000011, 2'b00, 3'd0), 3'd0, 1'b1);
        fs = 2'b01;
        legal("FS Initial: fadd.d",      opfp(5'b00000, 2'b01, 5'd2, 3'd0), 3'd0, 1'b0);
        fs = 2'b11;

        // ---- not FP at all ----
        insn = 32'h00000013; #1; check("addi: is_fp", is_fp, 1'b0); check("addi: illegal", illegal, 1'b0);
        insn = 32'h00003003; #1; check("ld: is_fp", is_fp, 1'b0);

        // ---- mapping ----
        insn = opfp(5'b00000, 2'b01, 5'd2, 3'd7); frm = 3'd3; #1;
        check("fadd.d dyn: op", op, QV_FP_ADD); check("fadd.d dyn: rm resolved", rm, 3'd3);
        check("fadd.d: fmt", fmt, 1'b1);
        check("fadd.d: operands", {r1u, r1f, r2u, r2f, r3u, rdw, rdf}, 7'b1111011);
        insn = opfp(5'b00001, 2'b00, 5'd2, 3'd1); #1;
        check("fsub.s: op/fmt/rm", {op, fmt, rm}, {QV_FP_SUB, 1'b0, 3'd1});
        insn = opfp(5'b00010, 2'b01, 5'd2, 3'd0); #1; check("fmul.d", op, QV_FP_MUL);
        insn = opfp(5'b00011, 2'b01, 5'd2, 3'd0); #1; check("fdiv.d", op, QV_FP_DIV);
        insn = opfp(5'b01011, 2'b01, 5'd0, 3'd0); #1;
        check("fsqrt.d", op, QV_FP_SQRT); check("fsqrt: rs2 not read", r2u, 1'b0);
        insn = r4(7'b1000011, 2'b01, 3'd0); #1; check("fmadd", op, QV_FP_MADD); check("fmadd: rs3", r3u, 1'b1);
        insn = r4(7'b1000111, 2'b01, 3'd0); #1; check("fmsub", op, QV_FP_MSUB);
        insn = r4(7'b1001011, 2'b01, 3'd0); #1; check("fnmsub", op, QV_FP_NMSUB);
        insn = r4(7'b1001111, 2'b00, 3'd0); #1; check("fnmadd.s", {op, fmt}, {QV_FP_NMADD, 1'b0});
        insn = opfp(5'b00100, 2'b01, 5'd2, 3'd1); #1; check("fsgnjn", op, QV_FP_SGNJN);
        insn = opfp(5'b00100, 2'b01, 5'd2, 3'd2); #1; check("fsgnjx", op, QV_FP_SGNJX);
        insn = opfp(5'b00101, 2'b01, 5'd2, 3'd0); #1; check("fmin", op, QV_FP_MIN);
        insn = opfp(5'b10100, 2'b01, 5'd2, 3'd2); #1;
        check("feq: op", op, QV_FP_EQ); check("feq: rd is an integer register", {rdw, rdf}, 2'b10);
        insn = opfp(5'b10100, 2'b01, 5'd2, 3'd1); #1; check("flt", op, QV_FP_LT);
        insn = opfp(5'b10100, 2'b01, 5'd2, 3'd0); #1; check("fle", op, QV_FP_LE);
        insn = opfp(5'b11000, 2'b01, 5'd1, 3'd0); #1;
        check("fcvt.wu.d: op/ityp", {op, ityp}, {QV_FP_F2I, 2'd1}); check("fcvt.wu.d: rd int", rdf, 1'b0);
        insn = opfp(5'b11010, 2'b00, 5'd2, 3'd0); #1;
        check("fcvt.s.l: op/ityp/fmt", {op, ityp, fmt}, {QV_FP_I2F, 2'd2, 1'b0});
        check("fcvt.s.l: rs1 int, rd fp", {r1u, r1f, rdf}, 3'b101);
        insn = opfp(5'b01000, 2'b00, 5'd1, 3'd0); #1; check("fcvt.s.d: op/fmt", {op, fmt}, {QV_FP_F2F, 1'b0});
        insn = opfp(5'b11100, 2'b00, 5'd0, 3'd0); #1;
        check("fmv.x.w: op/rd", {op, rdf}, {QV_FP_MV_XF, 1'b0});
        insn = opfp(5'b11100, 2'b01, 5'd0, 3'd1); #1; check("fclass", op, QV_FP_CLASS);
        insn = opfp(5'b11110, 2'b01, 5'd0, 3'd0); #1;
        check("fmv.d.x: op/rs1 int/rd fp", {op, r1f, rdf}, {QV_FP_MV_FX, 1'b0, 1'b1});
        insn = {12'hFF8, 5'd1, 3'b010, 5'd4, 7'b0000111}; #1;          // flw f4, -8(x1)
        check("flw: load, size 2, imm -8", {ld, st, msz, imm}, {1'b1, 1'b0, 2'd2, 64'hFFFF_FFFF_FFFF_FFF8});
        check("flw: rs1 int, rd fp", {r1u, r1f, r2u, rdw, rdf}, 5'b10011);
        insn = {7'h7F, 5'd2, 5'd1, 3'b011, 5'h18, 7'b0100111}; #1;     // fsd f2, -8(x1)
        check("fsd: store, size 3, imm -8", {ld, st, msz, imm}, {1'b0, 1'b1, 2'd3, 64'hFFFF_FFFF_FFFF_FFF8});
        check("fsd: rs1 int, rs2 fp, no rd", {r1u, r1f, r2u, r2f, rdw}, 5'b10110);

        $display("");
        $display("qv_fp_dec_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_fp_dec_tb: FAILURES PRESENT");
        $finish;
    end
endmodule
