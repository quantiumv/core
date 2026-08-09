// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: automated cross-check between testbench/riscv_encode.sv's
 * encode_amo() and the REAL riscv64-unknown-elf-as assembler's actual
 * bit-packing, for all 22 RV64A instructions plus a dedicated aq/rl sweep
 * -- the A-extension counterpart to m_encode_crosscheck_tb.sv.
 *
 * No clock, no reset, no DUT -- this never touches design/core.sv at all.
 * testbench/a_encode_check.s is assembled and objcopy'd to
 * a_encode_check.hex by testbench/Makefile (the real toolchain, not this
 * repo's own encoder); this testbench $readmemh's that golden hex into a
 * 26-entry array and, for each entry, calls encode_amo() with the operand
 * tuple hand-transcribed from that same .s file. A mismatch means either
 * the transcription is wrong or encode_amo() has a real bit-packing bug.
 *
 * The last 4 entries specifically prove aq/rl -- decoded directly from
 * the real assembler's own objdump output (independently confirmed: bit
 * 26 = aq, bit 25 = rl, exactly matching encode_amo's {funct5, aq, rl}
 * packing) -- lr.w.aq (aq=1,rl=0), sc.d.rl (aq=0,rl=1), amoadd.w.aqrl
 * (aq=1,rl=1), and a plain amoxor.d with neither suffix (aq=0,rl=0) as
 * the baseline contrast.
 *
 * a_encode_check.hex is one 32-bit word per instruction
 * (--verilog-data-width=4), so golden[i] lines up directly with program
 * order -- no half-word packing/byte-reversal to account for.
 */
module a_encode_crosscheck_tb;

    logic [31:0] golden [0:25];

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
        $readmemh("a_encode_check.hex", golden);

        check("idx0:  lr.w      x1,  (x2)",             golden[0],
              encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0,  5'd2,  `FUNCT3_AMO_W, 5'd1,  `OPC_AMO));
        check("idx1:  lr.d      x31, (x30)",             golden[1],
              encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0,  5'd30, `FUNCT3_AMO_D, 5'd31, `OPC_AMO));
        check("idx2:  sc.w      x16, x17, (x18)",        golden[2],
              encode_amo(`FUNCT5_SC, 1'b0, 1'b0, 5'd17, 5'd18, `FUNCT3_AMO_W, 5'd16, `OPC_AMO));
        check("idx3:  sc.d      x0,  x5,  (x6)",         golden[3],
              encode_amo(`FUNCT5_SC, 1'b0, 1'b0, 5'd5,  5'd6,  `FUNCT3_AMO_D, 5'd0,  `OPC_AMO));
        check("idx4:  amoswap.w x7,  x0,  (x8)",         golden[4],
              encode_amo(`FUNCT5_AMOSWAP, 1'b0, 1'b0, 5'd0,  5'd8,  `FUNCT3_AMO_W, 5'd7,  `OPC_AMO));
        check("idx5:  amoswap.d x9,  x10, (x0)",         golden[5],
              encode_amo(`FUNCT5_AMOSWAP, 1'b0, 1'b0, 5'd10, 5'd0,  `FUNCT3_AMO_D, 5'd9,  `OPC_AMO));
        check("idx6:  amoadd.w  x11, x31, (x1)",         golden[6],
              encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd31, 5'd1,  `FUNCT3_AMO_W, 5'd11, `OPC_AMO));
        check("idx7:  amoadd.d  x30, x2,  (x17)",        golden[7],
              encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd2,  5'd17, `FUNCT3_AMO_D, 5'd30, `OPC_AMO));
        check("idx8:  amoxor.w  x18, x29, (x3)",         golden[8],
              encode_amo(`FUNCT5_AMOXOR, 1'b0, 1'b0, 5'd29, 5'd3,  `FUNCT3_AMO_W, 5'd18, `OPC_AMO));
        check("idx9:  amoxor.d  x12, x16, (x31)",        golden[9],
              encode_amo(`FUNCT5_AMOXOR, 1'b0, 1'b0, 5'd16, 5'd31, `FUNCT3_AMO_D, 5'd12, `OPC_AMO));
        check("idx10: amoor.w   x19, x20, (x21)",        golden[10],
              encode_amo(`FUNCT5_AMOOR, 1'b0, 1'b0, 5'd20, 5'd21, `FUNCT3_AMO_W, 5'd19, `OPC_AMO));
        check("idx11: amoor.d   x22, x22, (x22)",        golden[11],
              encode_amo(`FUNCT5_AMOOR, 1'b0, 1'b0, 5'd22, 5'd22, `FUNCT3_AMO_D, 5'd22, `OPC_AMO));
        check("idx12: amoand.w  x28, x29, (x30)",        golden[12],
              encode_amo(`FUNCT5_AMOAND, 1'b0, 1'b0, 5'd29, 5'd30, `FUNCT3_AMO_W, 5'd28, `OPC_AMO));
        check("idx13: amoand.d  x31, x0,  (x31)",        golden[13],
              encode_amo(`FUNCT5_AMOAND, 1'b0, 1'b0, 5'd0,  5'd31, `FUNCT3_AMO_D, 5'd31, `OPC_AMO));
        check("idx14: amomin.w  x2,  x3,  (x1)",         golden[14],
              encode_amo(`FUNCT5_AMOMIN, 1'b0, 1'b0, 5'd3,  5'd1,  `FUNCT3_AMO_W, 5'd2,  `OPC_AMO));
        check("idx15: amomin.d  x17, x18, (x16)",        golden[15],
              encode_amo(`FUNCT5_AMOMIN, 1'b0, 1'b0, 5'd18, 5'd16, `FUNCT3_AMO_D, 5'd17, `OPC_AMO));
        check("idx16: amomax.w  x29, x30, (x31)",        golden[16],
              encode_amo(`FUNCT5_AMOMAX, 1'b0, 1'b0, 5'd30, 5'd31, `FUNCT3_AMO_W, 5'd29, `OPC_AMO));
        check("idx17: amomax.d  x20, x21, (x19)",        golden[17],
              encode_amo(`FUNCT5_AMOMAX, 1'b0, 1'b0, 5'd21, 5'd19, `FUNCT3_AMO_D, 5'd20, `OPC_AMO));
        check("idx18: amominu.w x23, x24, (x25)",        golden[18],
              encode_amo(`FUNCT5_AMOMINU, 1'b0, 1'b0, 5'd24, 5'd25, `FUNCT3_AMO_W, 5'd23, `OPC_AMO));
        check("idx19: amominu.d x26, x27, (x28)",        golden[19],
              encode_amo(`FUNCT5_AMOMINU, 1'b0, 1'b0, 5'd27, 5'd28, `FUNCT3_AMO_D, 5'd26, `OPC_AMO));
        check("idx20: amomaxu.w x1,  x31, (x0)",         golden[20],
              encode_amo(`FUNCT5_AMOMAXU, 1'b0, 1'b0, 5'd31, 5'd0,  `FUNCT3_AMO_W, 5'd1,  `OPC_AMO));
        check("idx21: amomaxu.d x0,  x1,  (x31)",        golden[21],
              encode_amo(`FUNCT5_AMOMAXU, 1'b0, 1'b0, 5'd1,  5'd31, `FUNCT3_AMO_D, 5'd0,  `OPC_AMO));

        // aq/rl sweep -- see header comment for the independently-confirmed bit positions.
        check("idx22: lr.w.aq       x4,  (x5)          [aq=1,rl=0]", golden[22],
              encode_amo(`FUNCT5_LR, 1'b1, 1'b0, 5'd0,  5'd5,  `FUNCT3_AMO_W, 5'd4,  `OPC_AMO));
        check("idx23: sc.d.rl       x6,  x7,  (x8)      [aq=0,rl=1]", golden[23],
              encode_amo(`FUNCT5_SC, 1'b0, 1'b1, 5'd7,  5'd8,  `FUNCT3_AMO_D, 5'd6,  `OPC_AMO));
        check("idx24: amoadd.w.aqrl x9,  x10, (x11)     [aq=1,rl=1]", golden[24],
              encode_amo(`FUNCT5_AMOADD, 1'b1, 1'b1, 5'd10, 5'd11, `FUNCT3_AMO_W, 5'd9,  `OPC_AMO));
        check("idx25: amoxor.d      x12, x13, (x14)     [aq=0,rl=0, baseline contrast]", golden[25],
              encode_amo(`FUNCT5_AMOXOR, 1'b0, 1'b0, 5'd13, 5'd14, `FUNCT3_AMO_D, 5'd12, `OPC_AMO));

        $display("");
        $display("a_encode_crosscheck_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("a_encode_crosscheck_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
