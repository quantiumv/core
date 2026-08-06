// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: automated cross-check between testbench/riscv_encode.sv's
 * encode_csr() and the REAL riscv64-unknown-elf-as assembler's actual
 * bit-packing (Pillar 2 of the Zicsr verification-strengthening plan).
 *
 * No clock, no reset, no DUT -- this never touches design/core.sv at all.
 * testbench/csr_encode_check.s is assembled and objcopy'd to
 * csr_encode_check.hex by testbench/Makefile (the real toolchain, not
 * this repo's own encoder); this testbench $readmemh's that golden hex
 * into a 12-entry array and, for each entry, calls encode_csr() with the
 * operand tuple hand-transcribed from that same .s file (see the table
 * below -- each check's name is the actual assembly line it encodes). A
 * mismatch means either the transcription is wrong or encode_csr() has a
 * real bit-packing bug -- both are worth catching, and unlike this
 * repo's other, entirely hand-derived testbenches, the golden side here
 * comes from an independent, real implementation of the ISA spec.
 *
 * csr_encode_check.hex is one 32-bit word per instruction
 * (--verilog-data-width=4), so golden[i] lines up directly with program
 * order -- no half-word packing/byte-reversal to account for (unlike
 * wb4_sram.sv's 64-bit firmware images).
 */
module riscv_encode_crosscheck_tb;

    logic [31:0] golden [0:11];

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
        $readmemh("csr_encode_check.hex", golden);

        check("idx0:  csrrw  x1,  mscratch,  x2",  golden[0],
              encode_csr(`CSR_MSCRATCH,  5'd2,  `FUNCT3_CSRRW,  5'd1,  `OPC_SYSTEM));
        check("idx1:  csrrw  x31, mcycle,    x30", golden[1],
              encode_csr(`CSR_MCYCLE,    5'd30, `FUNCT3_CSRRW,  5'd31, `OPC_SYSTEM));
        check("idx2:  csrrs  x16, minstret,  x17", golden[2],
              encode_csr(`CSR_MINSTRET,  5'd17, `FUNCT3_CSRRS,  5'd16, `OPC_SYSTEM));
        check("idx3:  csrrs  x0,  misa,      x5",  golden[3],
              encode_csr(`CSR_MISA,      5'd5,  `FUNCT3_CSRRS,  5'd0,  `OPC_SYSTEM));
        check("idx4:  csrrc  x3,  mvendorid, x4",  golden[4],
              encode_csr(`CSR_MVENDORID, 5'd4,  `FUNCT3_CSRRC,  5'd3,  `OPC_SYSTEM));
        check("idx5:  csrrc  x2,  0x7C0,     x1",  golden[5],
              encode_csr(12'h7C0,        5'd1,  `FUNCT3_CSRRC,  5'd2,  `OPC_SYSTEM));
        check("idx6:  csrrwi x1,  marchid,   0",   golden[6],
              encode_csr(`CSR_MARCHID,   5'd0,  `FUNCT3_CSRRWI, 5'd1,  `OPC_SYSTEM));
        check("idx7:  csrrwi x31, mimpid,    31",  golden[7],
              encode_csr(`CSR_MIMPID,    5'd31, `FUNCT3_CSRRWI, 5'd31, `OPC_SYSTEM));
        check("idx8:  csrrsi x16, mhartid,   15",  golden[8],
              encode_csr(`CSR_MHARTID,   5'd15, `FUNCT3_CSRRSI, 5'd16, `OPC_SYSTEM));
        check("idx9:  csrrsi x0,  0xFFF,     0",   golden[9],
              encode_csr(12'hFFF,        5'd0,  `FUNCT3_CSRRSI, 5'd0,  `OPC_SYSTEM));
        check("idx10: csrrci x30, mscratch,  31",  golden[10],
              encode_csr(`CSR_MSCRATCH,  5'd31, `FUNCT3_CSRRCI, 5'd30, `OPC_SYSTEM));
        check("idx11: csrrci x17, 0x7C0,     15",  golden[11],
              encode_csr(12'h7C0,        5'd15, `FUNCT3_CSRRCI, 5'd17, `OPC_SYSTEM));

        $display("");
        $display("riscv_encode_crosscheck_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("riscv_encode_crosscheck_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
