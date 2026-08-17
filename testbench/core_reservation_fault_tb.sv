// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, a faulted LR must NOT create a valid LR/SC
 * reservation.
 *
 * Closes a real gap found by code review of the bus-error-trapping
 * milestone: reservation_valid_q/reservation_addr_q (design/core.sv,
 * the LR/SC reservation register) were set on `commit_now && is_lr`
 * with no `!trap_taken` guard -- unlike reg_write/csr_we, which are
 * both correctly gated. Since is_lr is purely combinational/decode-
 * based and doesn't care whether the bus transaction actually
 * succeeded, a faulted LR (bus-error or misaligned) still set a
 * "valid" reservation for a load that never happened.
 *
 * Proof strategy: an LR.W to an out-of-range address (faults, cause 7,
 * same class as core_bus_fault_trap_tb.sv's test E) immediately
 * followed by an SC.W to the SAME address. If the reservation was
 * spuriously set, sc_addr_match/sc_success incorrectly evaluate true,
 * making mem_control treat the SC as a MATCHED store -- so it actually
 * attempts a real bus write to that same out-of-range address, which
 * itself then faults (cause 7 again), suppressing the SC's own
 * register write entirely (trap_taken blocks reg_write) -- leaving its
 * destination register at whatever sentinel it held before. With the
 * fix, no reservation exists, so sc_success is false, mem_control
 * treats the SC as a MISMATCH (no bus access needed at all -- pure
 * S_EXEC commit), and its destination register is correctly written to
 * 1 (SC failure, per spec). The two outcomes are cleanly distinguished
 * by one register's final value: 1 (correct) vs. the untouched
 * sentinel (bug).
 *
 * The trap handler resumes via mepc+4 (not a fixed resume address,
 * unlike core_bus_fault_trap_tb.sv's fetch-fault cases) specifically so
 * this test is robust to EITHER outcome: if the SC also faults (the bug
 * case), the handler fires a second time and correctly walks forward
 * past it too, so the program reaches ebreak either way -- only the
 * final register check tells them apart.
 */
module core_reservation_fault_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_wb4_sram_harness #(.NUM_WORDS(64)) dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    wire halted = dut.core0.halted;
    `include "halt_wait.sv"

    localparam int unsigned HANDLER_ADDR = 32'h40;
    localparam int unsigned OUT_OF_RANGE = 32'h10000;

    logic [31:0] main_prog[0:8];
    logic [31:0] handler_prog[0:3];
    int i;

    initial begin
        #1;

        /*
         * addr  instr                                    notes
         * 0x00  addi x28, x0, HANDLER_ADDR
         * 0x04  csrrw x0, mtvec, x28
         * 0x08  lui x5, 16                                x5 = 0x10000
         * 0x0C  addi x6, x0, 777                          sentinel, LR's rd
         * 0x10  lr.w x6, (x5)                              FAULTS (cause 7)
         * 0x14  addi x9, x0, 888                          sentinel, SC's rd
         * 0x18  addi x10, x0, 42                          rs2 for SC (irrelevant if mismatched)
         * 0x1C  sc.w x9, x10, (x5)                         must NOT fault; x9 <- 1
         * 0x20  ebreak
         */
        main_prog[0] = encode_i(int'(HANDLER_ADDR), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[1] = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[2] = encode_u(20'h10, 5'd5, `OPC_LUI);
        main_prog[3] = encode_i(32'sd777, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM);
        main_prog[4] = encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0, 5'd5, `FUNCT3_AMO_W, 5'd6, `OPC_AMO);
        main_prog[5] = encode_i(32'sd888, 5'd0, 3'b000, 5'd9, `OPC_OP_IMM);
        main_prog[6] = encode_i(32'sd42, 5'd0, 3'b000, 5'd10, `OPC_OP_IMM);
        main_prog[7] = encode_amo(`FUNCT5_SC, 1'b0, 1'b0, 5'd10, 5'd5, `FUNCT3_AMO_W, 5'd9, `OPC_AMO);
        main_prog[8] = encode_i(32'sd1, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM); // ebreak

        for (i = 0; i < 4; i = i + 1)
            dut.sram0.memory[i] = {main_prog[2*i+1], main_prog[2*i]};
        dut.sram0.memory[4][31:0] = main_prog[8]; // 0x20: ebreak, alone in its word's low half

        /*
         * addr  instr                                    notes
         * 0x40  csrrs x20, mepc, x0
         * 0x44  addi x20, x20, 4                          skip past the faulting instruction
         * 0x48  csrrw x0, mepc, x20
         * 0x4C  mret
         */
        handler_prog[0] = encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd20, `OPC_SYSTEM);
        handler_prog[1] = encode_i(32'sd4, 5'd20, 3'b000, 5'd20, `OPC_OP_IMM);
        handler_prog[2] = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[3] = `INSTR_HEX_MRET;

        for (i = 0; i < 2; i = i + 1)
            dut.sram0.memory[8+i] = {handler_prog[2*i+1], handler_prog[2*i]};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "dut.core0.halted never went high");

        check("faulted LR: dest register untouched (LR never happened)",
            dut.core0.regfile0.gp_registers[6], 64'd777);
        check({"SC to the same address after a faulted LR correctly reports FAILURE (rd=1) -- ",
            "NOT the untouched sentinel (888), which would mean the faulted LR spuriously ",
            "created a valid reservation and the SC's own write then also faulted"},
            dut.core0.regfile0.gp_registers[9], 64'd1);
        check("core halted (ebreak reached)", {63'b0, dut.core0.halted}, 64'd1);

        $display("");
        $display("core_reservation_fault_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_reservation_fault_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
