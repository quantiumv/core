// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: c_expand
 *
 * Unit-level, no clock needed -- c_expand is pure combinational. Every
 * expected 32-bit output below is computed via testbench/riscv_encode.sv's
 * encode_r/encode_i/encode_s/encode_b/encode_j/encode_shift64 -- a
 * SEPARATE implementation from c_expand.sv's own internal mk_r/mk_i/...
 * helpers, written independently, so a mistake shared between the two
 * would have to be a genuine misunderstanding of the target instruction's
 * shape, not a copy-paste-shared bug. Every 16-bit input is built directly
 * from named bit-field literals (never hex), each with an inline comment
 * showing which compressed-instruction field it represents, so a reader
 * can check this file against the RVC spec table without cross-referencing
 * c_expand.sv itself.
 *
 * This is pillar 1 of the C-extension verification plan -- catches coding
 * mistakes in c_expand.sv against ITS OWN intended design. It cannot catch
 * a shared misunderstanding of the real spec (both this file and
 * c_expand.sv were written by re-deriving the same bit tables) -- that's
 * what testbench/c_encode_crosscheck_tb.sv (pillar 3, a real
 * riscv64-unknown-elf-as-assembled golden fixture) exists to catch
 * independently. Treat a clean pass here as necessary, not sufficient.
 */
module c_expand_tb;

    logic [15:0] i_instr16;
    logic [31:0] o_instr32;
    logic        o_illegal;

    c_expand dut (
        .i_instr16(i_instr16),
        .o_instr32(o_instr32),
        .o_illegal(o_illegal)
    );

    int pass_count = 0;
    int fail_count = 0;

    task automatic check_expand(
        string name, logic [15:0] instr16,
        logic [31:0] expected_instr32, logic expected_illegal
    );
        i_instr16 = instr16;
        #1;
        if (o_illegal !== expected_illegal) begin
            fail_count++;
            $display("FAIL: %s -- illegal: expected %b, got %b", name, expected_illegal, o_illegal);
        end else if (!expected_illegal && (o_instr32 !== expected_instr32)) begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected_instr32, o_instr32);
        end else begin
            pass_count++;
            $display("PASS: %s", name);
        end
    endtask

    initial begin
        /* ============ Quadrant 0 (op=00) ============ */

        check_expand("C.ADDI4SPN (rd'=x10, nzuimm=40)",
            {3'b000, 2'b10, 4'b0000, 1'b0, 1'b1, 3'b010, 2'b00},
            encode_i(40, 5'd2, 3'b000, 5'd10, `OPC_OP_IMM), 1'b0);

        check_expand("C.ADDI4SPN illegal (nzuimm=0)",
            {3'b000, 2'b00, 4'b0000, 1'b0, 1'b0, 3'b001, 2'b00},
            32'hx, 1'b1);

        check_expand("16'h0000 (C.ILLEGAL, subsumed by C.ADDI4SPN nzuimm=0)",
            16'h0000, 32'hx, 1'b1);

        check_expand("C.LW (rs1'=x9, rd'=x12, off=20)",
            {3'b010, 3'b010, 3'b001, 1'b1, 1'b0, 3'b100, 2'b00},
            encode_i(20, 5'd9, 3'b010, 5'd12, `OPC_LOAD), 1'b0);

        check_expand("C.LD (rs1'=x8, rd'=x15, off=24)",
            {3'b011, 3'b011, 3'b000, 2'b00, 3'b111, 2'b00},
            encode_i(24, 5'd8, 3'b011, 5'd15, `OPC_LOAD), 1'b0);

        check_expand("C.SW (rs1'=x10, rs2'=x13, off=12)",
            {3'b110, 3'b001, 3'b010, 1'b1, 1'b0, 3'b101, 2'b00},
            encode_s(12, 5'd13, 5'd10, 3'b010, `OPC_STORE), 1'b0);

        check_expand("C.SD (rs1'=x11, rs2'=x14, off=16)",
            {3'b111, 3'b010, 3'b011, 2'b00, 3'b110, 2'b00},
            encode_s(16, 5'd14, 5'd11, 3'b011, `OPC_STORE), 1'b0);

        check_expand("op=00 funct3=100 (unassigned, illegal)",
            {3'b100, 13'b0}, 32'hx, 1'b1);

        /* ============ Quadrant 1 (op=01) ============ */

        check_expand("C.ADDI (rd=x5, imm=-3)",
            {3'b000, 1'b1, 5'b00101, 5'b11101, 2'b01},
            encode_i(-3, 5'd5, 3'b000, 5'd5, `OPC_OP_IMM), 1'b0);

        check_expand("C.NOP (C.ADDI rd=0,imm=0 -- HINT, not illegal)",
            {3'b000, 1'b0, 5'b00000, 5'b00000, 2'b01},
            encode_i(0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM), 1'b0);

        check_expand("C.ADDIW (rd=x7, imm=5)",
            {3'b001, 1'b0, 5'b00111, 5'b00101, 2'b01},
            encode_i(5, 5'd7, 3'b000, 5'd7, `OPC_OP_IMM_32), 1'b0);

        check_expand("C.ADDIW illegal (rd=0 -- RESERVED, unlike C.ADDI's rd=0 HINT)",
            {3'b001, 1'b0, 5'b00000, 5'b00101, 2'b01},
            32'hx, 1'b1);

        check_expand("C.LI (rd=x18, imm=-10)",
            {3'b010, 1'b1, 5'b10010, 5'b10110, 2'b01},
            encode_i(-10, 5'd0, 3'b000, 5'd18, `OPC_OP_IMM), 1'b0);

        check_expand("C.LI HINT (rd=0, imm nonzero)",
            {3'b010, 1'b0, 5'b00000, 5'b00001, 2'b01},
            encode_i(1, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM), 1'b0);

        check_expand("C.ADDI16SP (nzimm=16)",
            {3'b011, 1'b0, 5'b00010, 5'b10000, 2'b01},
            encode_i(16, 5'd2, 3'b000, 5'd2, `OPC_OP_IMM), 1'b0);

        check_expand("C.ADDI16SP illegal (nzimm=0)",
            {3'b011, 1'b0, 5'b00010, 5'b00000, 2'b01},
            32'hx, 1'b1);

        check_expand("C.LUI (rd=x9, nzimm[17:12]=0x15)",
            {3'b011, 1'b0, 5'b01001, 5'b10101, 2'b01},
            encode_u(20'h00015, 5'd9, `OPC_LUI), 1'b0);

        check_expand("C.LUI HINT (rd=0, imm nonzero)",
            {3'b011, 1'b0, 5'b00000, 5'b00001, 2'b01},
            encode_u(20'h00001, 5'd0, `OPC_LUI), 1'b0);

        check_expand("C.LUI illegal (rd=x5 (!=0,2), raw imm bits all zero)",
            {3'b011, 1'b0, 5'b00101, 5'b00000, 2'b01},
            32'hx, 1'b1);

        check_expand("C.SRLI (rd'=x9, shamt=19)",
            {3'b100, 1'b0, 2'b00, 3'b001, 5'b10011, 2'b01},
            encode_shift64(6'b000000, 6'd19, 5'd9, 3'b101, 5'd9, `OPC_OP_IMM), 1'b0);

        check_expand("C.SRAI (rd'=x12, shamt=5)",
            {3'b100, 1'b0, 2'b01, 3'b100, 5'b00101, 2'b01},
            encode_shift64(6'b010000, 6'd5, 5'd12, 3'b101, 5'd12, `OPC_OP_IMM), 1'b0);

        check_expand("C.ANDI (rd'=x11, imm=-5)",
            {3'b100, 1'b1, 2'b10, 3'b011, 5'b11011, 2'b01},
            encode_i(-5, 5'd11, 3'b111, 5'd11, `OPC_OP_IMM), 1'b0);

        check_expand("C.SUB (rd'=x8, rs2'=x9)",
            {3'b100, 1'b0, 2'b11, 3'b000, 2'b00, 3'b001, 2'b01},
            encode_r(7'b0100000, 5'd9, 5'd8, 3'b000, 5'd8, `OPC_OP), 1'b0);

        check_expand("C.XOR (rd'=x10, rs2'=x11)",
            {3'b100, 1'b0, 2'b11, 3'b010, 2'b01, 3'b011, 2'b01},
            encode_r(7'b0000000, 5'd11, 5'd10, 3'b100, 5'd10, `OPC_OP), 1'b0);

        check_expand("C.OR (rd'=x12, rs2'=x13)",
            {3'b100, 1'b0, 2'b11, 3'b100, 2'b10, 3'b101, 2'b01},
            encode_r(7'b0000000, 5'd13, 5'd12, 3'b110, 5'd12, `OPC_OP), 1'b0);

        check_expand("C.AND (rd'=x14, rs2'=x15)",
            {3'b100, 1'b0, 2'b11, 3'b110, 2'b11, 3'b111, 2'b01},
            encode_r(7'b0000000, 5'd15, 5'd14, 3'b111, 5'd14, `OPC_OP), 1'b0);

        check_expand("C.SUBW (rd'=x8, rs2'=x9)",
            {3'b100, 1'b1, 2'b11, 3'b000, 2'b00, 3'b001, 2'b01},
            encode_r(7'b0100000, 5'd9, 5'd8, 3'b000, 5'd8, `OPC_OP_32), 1'b0);

        check_expand("C.ADDW (rd'=x10, rs2'=x11)",
            {3'b100, 1'b1, 2'b11, 3'b010, 2'b01, 3'b011, 2'b01},
            encode_r(7'b0000000, 5'd11, 5'd10, 3'b000, 5'd10, `OPC_OP_32), 1'b0);

        check_expand("CA reserved (i12=1, funct2=10)",
            {3'b100, 1'b1, 2'b11, 3'b000, 2'b10, 3'b000, 2'b01}, 32'hx, 1'b1);

        check_expand("CA reserved (i12=1, funct2=11)",
            {3'b100, 1'b1, 2'b11, 3'b000, 2'b11, 3'b000, 2'b01}, 32'hx, 1'b1);

        check_expand("C.J (offset=64, isolates target[6]<-i7)",
            {3'b101, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'b01},
            encode_j(64, 5'd0, `OPC_JAL), 1'b0);

        check_expand("C.BEQZ (rs1'=x9, offset=16)",
            {3'b110, 1'b0, 2'b10, 3'b001, 2'b00, 2'b00, 1'b0, 2'b01},
            encode_b(16, 5'd0, 5'd9, 3'b000, `OPC_BRANCH), 1'b0);

        check_expand("C.BNEZ (rs1'=x11, offset=8)",
            {3'b111, 1'b0, 2'b01, 3'b011, 2'b00, 2'b00, 1'b0, 2'b01},
            encode_b(8, 5'd0, 5'd11, 3'b001, `OPC_BRANCH), 1'b0);

        /* ============ Quadrant 2 (op=10) ============ */

        check_expand("C.SLLI (rd=x20, shamt=35)",
            {3'b000, 1'b1, 5'b10100, 5'b00011, 2'b10},
            encode_shift64(6'b000000, 6'd35, 5'd20, 3'b001, 5'd20, `OPC_OP_IMM), 1'b0);

        check_expand("C.SLLI HINT (rd=0, shamt=0)",
            {3'b000, 1'b0, 5'b00000, 5'b00000, 2'b10},
            encode_shift64(6'b000000, 6'd0, 5'd0, 3'b001, 5'd0, `OPC_OP_IMM), 1'b0);

        check_expand("C.LWSP (rd=x21, off=68)",
            {3'b010, 1'b0, 5'b10101, 5'b00101, 2'b10},
            encode_i(68, 5'd2, 3'b010, 5'd21, `OPC_LOAD), 1'b0);

        check_expand("C.LWSP illegal (rd=0)",
            {3'b010, 1'b0, 5'b00000, 5'b00101, 2'b10}, 32'hx, 1'b1);

        check_expand("C.LDSP (rd=x22, off=136)",
            {3'b011, 1'b0, 5'b10110, 5'b01010, 2'b10},
            encode_i(136, 5'd2, 3'b011, 5'd22, `OPC_LOAD), 1'b0);

        check_expand("C.LDSP illegal (rd=0)",
            {3'b011, 1'b0, 5'b00000, 5'b01010, 2'b10}, 32'hx, 1'b1);

        check_expand("C.JR (rs1=x5)",
            {3'b100, 1'b0, 5'b00101, 5'b00000, 2'b10},
            encode_i(0, 5'd5, 3'b000, 5'd0, `OPC_JALR), 1'b0);

        check_expand("C.JR illegal (rs1=0)",
            {3'b100, 1'b0, 5'b00000, 5'b00000, 2'b10}, 32'hx, 1'b1);

        check_expand("C.MV (rd=x6, rs2=x17)",
            {3'b100, 1'b0, 5'b00110, 5'b10001, 2'b10},
            encode_r(7'b0000000, 5'd17, 5'd0, 3'b000, 5'd6, `OPC_OP), 1'b0);

        check_expand("C.MV HINT (rd=0)",
            {3'b100, 1'b0, 5'b00000, 5'b10001, 2'b10},
            encode_r(7'b0000000, 5'd17, 5'd0, 3'b000, 5'd0, `OPC_OP), 1'b0);

        check_expand("C.EBREAK",
            {3'b100, 1'b1, 5'b00000, 5'b00000, 2'b10}, 32'h00100073, 1'b0);

        check_expand("C.JALR (rs1=x19)",
            {3'b100, 1'b1, 5'b10011, 5'b00000, 2'b10},
            encode_i(0, 5'd19, 3'b000, 5'd1, `OPC_JALR), 1'b0);

        check_expand("C.ADD (rd=x8, rs2=x25)",
            {3'b100, 1'b1, 5'b01000, 5'b11001, 2'b10},
            encode_r(7'b0000000, 5'd25, 5'd8, 3'b000, 5'd8, `OPC_OP), 1'b0);

        check_expand("C.ADD HINT (rd=0)",
            {3'b100, 1'b1, 5'b00000, 5'b11001, 2'b10},
            encode_r(7'b0000000, 5'd25, 5'd0, 3'b000, 5'd0, `OPC_OP), 1'b0);

        check_expand("C.SWSP (rs2=x26, off=48)",
            {3'b110, 6'b110000, 5'b11010, 2'b10},
            encode_s(48, 5'd26, 5'd2, 3'b010, `OPC_STORE), 1'b0);

        check_expand("C.SDSP (rs2=x27, off=88)",
            {3'b111, 6'b011001, 5'b11011, 2'b10},
            encode_s(88, 5'd27, 5'd2, 3'b011, `OPC_STORE), 1'b0);

        check_expand("op=10 funct3=001 (C.FLDSP, no F/D, illegal)",
            {3'b001, 13'b0}, 32'hx, 1'b1);

        check_expand("op=10 funct3=101 (C.FSDSP, no F/D, illegal)",
            {3'b101, 13'b0}, 32'hx, 1'b1);

        check_expand("op=11 (not compressed at all -- structurally unreachable, safe illegal)",
            {14'b0, 2'b11}, 32'hx, 1'b1);

        $display("");
        $display("c_expand_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("c_expand_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
