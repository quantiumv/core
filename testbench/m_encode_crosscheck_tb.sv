// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: automated cross-check between testbench/riscv_encode.sv's
 * encode_r() and the REAL riscv64-unknown-elf-as assembler's actual
 * bit-packing, for all 13 RV64M instructions (Pillar D of the M-extension
 * verification-strengthening plan -- the M-extension counterpart to
 * riscv_encode_crosscheck_tb.sv's Pillar 2 for Zicsr).
 *
 * No clock, no reset, no DUT -- this never touches design/core.sv at all.
 * testbench/m_encode_check.s is assembled and objcopy'd to
 * m_encode_check.hex by testbench/Makefile (the real toolchain, not this
 * repo's own encoder); this testbench $readmemh's that golden hex into a
 * 13-entry array and, for each entry, calls encode_r() with the operand
 * tuple hand-transcribed from that same .s file (see the table below --
 * each check's name is the actual assembly line it encodes). A mismatch
 * means either the transcription is wrong or encode_r() has a real
 * bit-packing bug -- both are worth catching, and unlike this repo's
 * other, entirely hand-derived testbenches, the golden side here comes
 * from an independent, real implementation of the ISA spec.
 *
 * Unlike Zicsr (which needed a new encode_csr() wrapper), every M
 * instruction is plain R-type, so this reuses encode_r() as-is -- already
 * proven correct for the base ALU reg-reg ops. The real value of this
 * pillar is confirming that the SPECIFIC funct7=0000001 / funct3 / opcode
 * combination used at each M-extension call site throughout
 * testbench/core_m_ext_tb.sv (and, transitively,
 * design/defaults/instructions_and_masks.sv's own MUL_INSTR_CREATE/
 * MUL32_INSTR_CREATE macros) is exactly what the real assembler
 * independently produces for each of the 13 M mnemonics -- catching any
 * transcription slip in a funct3/funct7 value that this project's own
 * encoder and decoder would otherwise just self-consistently agree on
 * without ever being checked against ground truth.
 *
 * m_encode_check.hex is one 32-bit word per instruction
 * (--verilog-data-width=4), so golden[i] lines up directly with program
 * order -- no half-word packing/byte-reversal to account for (unlike
 * wb4_sram.sv's 64-bit firmware images).
 */
module m_encode_crosscheck_tb;

    logic [31:0] golden [0:12];

    int pass_count = 0;
    int fail_count = 0;
    task automatic check(string name, logic [31:0] actual, logic [31:0] expected);
        if (actual === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    initial begin
        $readmemh("m_encode_check.hex", golden);

        // 64-bit reg-reg M forms: opcode OPC_OP (0110011), funct7=0000001.
        check("idx0:  mul    x1,  x2,  x3",   golden[0],
              encode_r(7'b0000001, 5'd3,  5'd2,  3'b000, 5'd1,  `OPC_OP));
        check("idx1:  mulh   x31, x30, x29",  golden[1],
              encode_r(7'b0000001, 5'd29, 5'd30, 3'b001, 5'd31, `OPC_OP));
        check("idx2:  mulhsu x16, x17, x18",  golden[2],
              encode_r(7'b0000001, 5'd18, 5'd17, 3'b010, 5'd16, `OPC_OP));
        check("idx3:  mulhu  x0,  x5,  x6",   golden[3],
              encode_r(7'b0000001, 5'd6,  5'd5,  3'b011, 5'd0,  `OPC_OP));
        check("idx5:  div    x9,  x10, x0",   golden[5],
              encode_r(7'b0000001, 5'd0,  5'd10, 3'b100, 5'd9,  `OPC_OP));
        check("idx6:  divu   x11, x31, x1",   golden[6],
              encode_r(7'b0000001, 5'd1,  5'd31, 3'b101, 5'd11, `OPC_OP));
        check("idx7:  rem    x30, x2,  x17",  golden[7],
              encode_r(7'b0000001, 5'd17, 5'd2,  3'b110, 5'd30, `OPC_OP));
        check("idx8:  remu   x18, x29, x3",   golden[8],
              encode_r(7'b0000001, 5'd3,  5'd29, 3'b111, 5'd18, `OPC_OP));

        // 32-bit *W reg-reg M forms: opcode OPC_OP_32 (0111011), funct7=0000001.
        check("idx4:  mulw   x7,  x0,  x8",   golden[4],
              encode_r(7'b0000001, 5'd8,  5'd0,  3'b000, 5'd7,  `OPC_OP_32));
        check("idx9:  divw   x12, x16, x31",  golden[9],
              encode_r(7'b0000001, 5'd31, 5'd16, 3'b100, 5'd12, `OPC_OP_32));
        check("idx10: divuw  x19, x20, x21",  golden[10],
              encode_r(7'b0000001, 5'd21, 5'd20, 3'b101, 5'd19, `OPC_OP_32));
        check("idx11: remw   x22, x22, x22",  golden[11],
              encode_r(7'b0000001, 5'd22, 5'd22, 3'b110, 5'd22, `OPC_OP_32));
        check("idx12: remuw  x31, x0,  x31",  golden[12],
              encode_r(7'b0000001, 5'd31, 5'd0,  3'b111, 5'd31, `OPC_OP_32));

        $display("");
        $display("m_encode_crosscheck_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("m_encode_crosscheck_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
