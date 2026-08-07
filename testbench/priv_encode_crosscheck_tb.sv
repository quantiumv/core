// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: automated cross-check between testbench/riscv_encode.sv's
 * `INSTR_HEX_MRET/`INSTR_HEX_SRET/`INSTR_HEX_WFI/encode_r()+
 * `FUNCT7_SFENCE_VMA and the REAL riscv64-unknown-elf-as assembler's
 * actual bit-packing, for all four U/S/M privilege-mode instructions
 * (Pillar D of the privilege-mode verification-strengthening plan -- the
 * privilege-mode counterpart to riscv_encode_crosscheck_tb.sv's Pillar 2
 * for Zicsr and m_encode_crosscheck_tb.sv's Pillar D for M-extension).
 *
 * No clock, no reset, no DUT -- this never touches design/core.sv at all.
 * testbench/priv_encode_check.s is assembled and objcopy'd to
 * priv_encode_check.hex by testbench/Makefile (the real toolchain, not
 * this repo's own encoder); this testbench $readmemh's that golden hex
 * into a 9-entry array and, for each entry, compares it against either a
 * fixed `INSTR_HEX_* literal or an encode_r() call with the operand tuple
 * hand-transcribed from that same .s file (see the table below -- each
 * check's name is the actual assembly line it encodes). A mismatch means
 * either the transcription is wrong, one of the three hand-derived
 * `INSTR_HEX_* literals has a real bit-packing bug, or encode_r() itself
 * does -- all three are worth catching, and unlike this repo's other,
 * entirely hand-derived testbenches, the golden side here comes from an
 * independent, real implementation of the ISA spec.
 *
 * Unlike Zicsr/M (where the whole point was checking a general-purpose
 * encoder function), mret/sret/wfi have NO operand fields at all -- each
 * is a single fixed 32-bit pattern -- so the real value of checks idx0-2
 * below is confirming that `INSTR_HEX_MRET=32'h30200073,
 * `INSTR_HEX_SRET=32'h10200073, and `INSTR_HEX_WFI=32'h10500073 (each
 * independently hand-verified this session via bit-field decomposition,
 * but never checked against a real assembler until now) are actually
 * correct. sfence.vma DOES take real rs1/rs2 operands, so checks idx3-8
 * instead confirm encode_r()'s general mechanism combined with
 * `FUNCT7_SFENCE_VMA=7'b0001001 matches the real assembler across a
 * spread of operand values, same discipline as the M-extension pillar's
 * per-mnemonic sweep.
 *
 * priv_encode_check.hex is one 32-bit word per instruction
 * (--verilog-data-width=4), so golden[i] lines up directly with program
 * order -- no half-word packing/byte-reversal to account for (unlike
 * wb4_sram.sv's 64-bit firmware images).
 */
module priv_encode_crosscheck_tb;

    logic [31:0] golden [0:8];

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
        $readmemh("priv_encode_check.hex", golden);

        // Fixed 32-bit patterns, zero operand fields -- the real point of
        // this pillar is confirming these three hand-derived literals
        // against the real assembler's own output.
        check("idx0: mret", golden[0], `INSTR_HEX_MRET);
        check("idx1: sret", golden[1], `INSTR_HEX_SRET);
        check("idx2: wfi",  golden[2], `INSTR_HEX_WFI);

        // sfence.vma x0, x0 -- the spec's "flush everything" idiom: both
        // operand fields zero simultaneously, distinct from either
        // single-zero case below.
        check("idx3: sfence.vma x0,  x0",  golden[3],
              encode_r(`FUNCT7_SFENCE_VMA, 5'd0,  5'd0,  3'b000, 5'd0, `OPC_SYSTEM));
        // Low register-index pair, mirroring csr_encode_check.s's own
        // low/mid/max spread.
        check("idx4: sfence.vma x1,  x2",  golden[4],
              encode_r(`FUNCT7_SFENCE_VMA, 5'd2,  5'd1,  3'b000, 5'd0, `OPC_SYSTEM));
        // Mid register-index pair.
        check("idx5: sfence.vma x16, x17", golden[5],
              encode_r(`FUNCT7_SFENCE_VMA, 5'd17, 5'd16, 3'b000, 5'd0, `OPC_SYSTEM));
        // Max register-index pair.
        check("idx6: sfence.vma x30, x31", golden[6],
              encode_r(`FUNCT7_SFENCE_VMA, 5'd31, 5'd30, 3'b000, 5'd0, `OPC_SYSTEM));
        // Asymmetric: rs1=x0 (all ASIDs) with rs2 nonzero (single vaddr) --
        // a bit-packing bug that only shows up when exactly one field is
        // zero wouldn't be caught by the all-zero or all-nonzero cases
        // alone.
        check("idx7: sfence.vma x0,  x31", golden[7],
              encode_r(`FUNCT7_SFENCE_VMA, 5'd31, 5'd0,  3'b000, 5'd0, `OPC_SYSTEM));
        // Asymmetric, mirrored: rs1 nonzero (single vaddr) with rs2=x0
        // (all ASIDs) -- confirms rs1/rs2 aren't swapped in encode_r()'s
        // field placement.
        check("idx8: sfence.vma x31, x0",  golden[8],
              encode_r(`FUNCT7_SFENCE_VMA, 5'd0,  5'd31, 3'b000, 5'd0, `OPC_SYSTEM));

        $display("");
        $display("priv_encode_crosscheck_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("priv_encode_crosscheck_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
