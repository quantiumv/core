// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: automated cross-check between testbench/riscv_encode.sv's
 * encode_c*() family and the REAL riscv64-unknown-elf-as assembler's
 * actual bit-packing, for all 38 lines of testbench/c_encode_check.s
 * (every RV64 Zca mnemonic, plus 6 c.nop fillers around the 3 branch/
 * jump instructions) -- the C-extension counterpart to
 * a_encode_crosscheck_tb.sv/m_encode_crosscheck_tb.sv.
 *
 * No clock, no reset, no DUT -- this never touches design/core.sv or
 * design/c_expand.sv at all. c_encode_check.s is assembled and objcopy'd
 * to c_encode_check.hex by testbench/Makefile (the real toolchain, not
 * this repo's own encoder); this testbench $readmemh's that golden hex
 * into a 38-entry 16-bit array and, for each entry, calls the matching
 * encode_c*() with the operand tuple hand-transcribed from that same .s
 * file. A mismatch means either the transcription is wrong or one of
 * riscv_encode.sv's encode_c*() functions has a real bit-packing bug --
 * genuinely independent of design/c_expand.sv's own (separately written)
 * mk_r/mk_i/... helpers, so this exercises a different implementation of
 * the same RVC bit tables than design/c_expand_tb.sv's unit test does.
 *
 * c_encode_check.hex is one 16-bit word per instruction
 * (--verilog-data-width=2), so golden[i] lines up directly with program
 * order -- no byte-reversal/packing to account for.
 */
module c_encode_crosscheck_tb;

    logic [15:0] golden [0:37];

    int pass_count = 0;
    int fail_count = 0;
    task automatic check(string name, logic [15:0] actual, logic [15:0] expected);
        if (actual === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    initial begin
        $readmemh("c_encode_check.hex", golden);

        check("idx0:  c.addi4spn x8,x2,32",   golden[0],  encode_c_addi4spn(10'd32, 3'd0));
        check("idx1:  c.lw       x9,4(x10)",  golden[1],  encode_c_lw(7'd4, 3'd2, 3'd1));
        check("idx2:  c.ld       x11,8(x12)", golden[2],  encode_c_ld(8'd8, 3'd4, 3'd3));
        check("idx3:  c.sw       x13,12(x14)",golden[3],  encode_c_sw(7'd12, 3'd6, 3'd5));
        check("idx4:  c.sd       x15,16(x8)", golden[4],  encode_c_sd(8'd16, 3'd0, 3'd7));

        check("idx5:  c.addi     x5,-7",      golden[5],  encode_c_addi(-7, 5'd5));
        check("idx6:  c.addiw    x6,9",       golden[6],  encode_c_addiw(9, 5'd6));
        check("idx7:  c.li       x7,-30",     golden[7],  encode_c_li(-30, 5'd7));
        check("idx8:  c.addi16sp 48",         golden[8],  encode_c_addi16sp(48));
        check("idx9:  c.lui      x18,31",     golden[9],  encode_c_lui(6'd31, 5'd18));

        check("idx10: c.srli     x9,19",      golden[10], encode_c_srli(6'd19, 3'd1));
        check("idx11: c.srai     x11,5",      golden[11], encode_c_srai(6'd5, 3'd3));
        check("idx12: c.andi     x9,-3",      golden[12], encode_c_andi(-3, 3'd1));
        check("idx13: c.sub      x9,x11",     golden[13], encode_c_ca(1'b0, `CA_FUNCT2_SUB, 3'd1, 3'd3));
        check("idx14: c.xor      x9,x11",     golden[14], encode_c_ca(1'b0, `CA_FUNCT2_XOR, 3'd1, 3'd3));
        check("idx15: c.or       x9,x11",     golden[15], encode_c_ca(1'b0, `CA_FUNCT2_OR, 3'd1, 3'd3));
        check("idx16: c.and      x9,x11",     golden[16], encode_c_ca(1'b0, `CA_FUNCT2_AND, 3'd1, 3'd3));
        check("idx17: c.subw     x9,x11",     golden[17], encode_c_ca(1'b1, `CA_FUNCT2_SUB, 3'd1, 3'd3));
        check("idx18: c.addw     x9,x11",     golden[18], encode_c_ca(1'b1, `CA_FUNCT2_XOR, 3'd1, 3'd3));

        check("idx19: c.j        jtarget (+6)",     golden[19], encode_c_j(6));
        check("idx20: c.nop (filler 1)",             golden[20], encode_c_addi(0, 5'd0));
        check("idx21: c.nop (filler 2)",             golden[21], encode_c_addi(0, 5'd0));
        check("idx22: c.beqz     x9,btarget (+6)",   golden[22], encode_c_beqz(6, 3'd1));
        check("idx23: c.nop (filler 3)",             golden[23], encode_c_addi(0, 5'd0));
        check("idx24: c.nop (filler 4)",             golden[24], encode_c_addi(0, 5'd0));
        check("idx25: c.bnez     x11,btarget2 (+6)", golden[25], encode_c_bnez(6, 3'd3));
        check("idx26: c.nop (filler 5)",             golden[26], encode_c_addi(0, 5'd0));
        check("idx27: c.nop (filler 6)",             golden[27], encode_c_addi(0, 5'd0));

        check("idx28: c.slli     x18,35",     golden[28], encode_c_slli(6'd35, 5'd18));
        check("idx29: c.lwsp     x18,68(x2)", golden[29], encode_c_lwsp(8'd68, 5'd18));
        check("idx30: c.ldsp     x18,136(x2)",golden[30], encode_c_ldsp(9'd136, 5'd18));
        check("idx31: c.jr       x5",         golden[31], encode_c_jr(5'd5));
        check("idx32: c.mv       x6,x18",     golden[32], encode_c_mv(5'd6, 5'd18));
        check("idx33: c.ebreak",              golden[33], `INSTR_C_EBREAK);
        check("idx34: c.jalr     x5",         golden[34], encode_c_jalr(5'd5));
        check("idx35: c.add      x6,x18",     golden[35], encode_c_add(5'd6, 5'd18));
        check("idx36: c.swsp     x18,48(x2)", golden[36], encode_c_swsp(8'd48, 5'd18));
        check("idx37: c.sdsp     x18,88(x2)", golden[37], encode_c_sdsp(9'd88, 5'd18));

        $display("");
        $display("c_encode_crosscheck_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("c_encode_crosscheck_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
