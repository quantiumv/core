// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, an AMO write-phase fault (the read phase succeeds,
 * the write phase to the SAME address faults), proving trap_val uses
 * amo_addr_q rather than mem_paddr for this specific case.
 *
 * Why this needs its own harness (core_amo_write_fault_harness.sv, not
 * core_wb4_sram_harness): wb4_sram.sv's address check is symmetric for
 * read vs. write, so "read succeeds, write to the same address faults"
 * can't be constructed through it. See that harness's own header.
 *
 * Why this is worth a dedicated, separate test (not folded into
 * core_bus_fault_trap_tb.sv's test F, which covers the AMO READ-phase
 * fault): mem_paddr(=alu_result) is live/correct during S_MEM, but gets
 * REPURPOSED to hold the AMO's computed modify value the instant
 * S_AMO_WRITE begins -- design/core.sv's trap_val must use amo_addr_q
 * (a dedicated, stable register) instead for a write-phase fault, or
 * mtval reports garbage. Test F can't exercise this at all (its fault
 * fires during the read phase, before S_AMO_WRITE -- and never using
 * S_AMO_WRITE's stale mem_paddr in the first place isn't proof the
 * *other* branch, S_AMO_WRITE's own trap_val arm, picked the right
 * source either).
 *
 * Operands are chosen so a mem_paddr-instead-of-amo_addr_q bug is
 * trivially distinguishable from the correct result: AMOADD with old
 * value 100 (core_amo_write_fault_harness.sv's fixed read-return value)
 * and rs2=5 computes a modify value of 105. A buggy trap_val reading
 * the repurposed mem_paddr during S_AMO_WRITE would report mtval=105;
 * the correct implementation reports the real target address, 0x1000 --
 * two very different, unmistakable numbers, not an off-by-a-bit case
 * that could be missed by accident.
 */
module core_amo_write_fault_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_amo_write_fault_harness #(.NUM_WORDS(64)) dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    logic halted = 1'b0;
    always @(posedge clk) if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"

    localparam int unsigned HANDLER_ADDR = 32'h40;
    localparam int unsigned AMO_TARGET   = 32'h1000;

    logic [31:0] main_prog[0:5];
    logic [31:0] handler_prog[0:3];
    int i;

    initial begin
        #1;

        /*
         * addr  instr                                    notes
         * 0x00  addi x28, x0, HANDLER_ADDR
         * 0x04  csrrw x0, mtvec, x28
         * 0x08  lui x5, 1                                 x5 = 0x1000
         * 0x0C  addi x6, x0, 5                             x6 = 5 (rs2 operand)
         * 0x10  amoadd.w x7, x6, (x5)                      read succeeds (100),
         *                                                   WRITE FAULTS
         * 0x14  ebreak                                     never reached directly
         */
        main_prog[0] = encode_i(int'(HANDLER_ADDR), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[1] = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[2] = encode_u(20'h1, 5'd5, `OPC_LUI);
        main_prog[3] = encode_i(32'sd5, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM);
        main_prog[4] = encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd6, 5'd5, `FUNCT3_AMO_W, 5'd7, `OPC_AMO);
        main_prog[5] = encode_i(32'sd1, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM); // ebreak

        for (i = 0; i < 3; i = i + 1)
            dut.memory[i] = {main_prog[2*i+1], main_prog[2*i]};

        /*
         * addr  instr                                    notes
         * 0x40  csrrs x10, mcause, x0
         * 0x44  csrrs x11, mtval, x0
         * 0x48  ebreak
         * 0x4C  (padding, never fetched)
         */
        handler_prog[0] = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM);
        handler_prog[1] = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd11, `OPC_SYSTEM);
        handler_prog[2] = encode_i(32'sd1, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM); // ebreak
        handler_prog[3] = encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM); // padding

        for (i = 0; i < 2; i = i + 1)
            dut.memory[8+i] = {handler_prog[2*i+1], handler_prog[2*i]};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "EBREAK trap never fired");

        check("AMO write-phase fault: mcause == 7 (store/AMO access fault)",
            dut.core0.regfile0.gp_registers[10], 64'd7);
        check("AMO write-phase fault: mtval == the real target address (0x1000), NOT the repurposed mem_paddr modify value (105)",
            dut.core0.regfile0.gp_registers[11], 64'(AMO_TARGET));
        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_amo_write_fault_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_amo_write_fault_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
