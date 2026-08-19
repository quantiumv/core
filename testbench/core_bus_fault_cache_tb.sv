// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, two bus-error traps through the REAL cache path
 * (core_cache_harness.sv -- core -> cache_complex -> icache0/dcache0 ->
 * wb4_sram), the one harness that actually exercises the paired
 * ack_o+err_o convention icache.sv/dcache.sv use on a downstream error
 * (unlike wb4_sram.sv's own genuinely-unpaired convention, which
 * core_bus_fault_trap_tb.sv/core_amo_write_fault_tb.sv already cover).
 *
 * Test J is the one that actually matters here: an AMO read-phase fault
 * through the cached path is the single scenario that distinguishes a
 * correct `wb_ok`-gated S_MEM -> S_AMO_WRITE decision from a buggy
 * bare-`wb_ack_i` one -- through the cache, a downstream error arrives
 * WITH wb_ack_i also asserted (icache.sv/dcache.sv's CACHE_REFILL error
 * arm sets both together), so a buggy implementation that only checks
 * wb_ack_i would incorrectly see "success" and proceed into
 * S_AMO_WRITE, issuing a real, bogus second bus write. The equivalent
 * test through core_wb4_sram_harness (core_bus_fault_trap_tb.sv's test
 * F) cannot catch this specific bug class at all, since wb4_sram.sv
 * never pairs ack and err in the first place.
 *
 * Both accesses target an address well beyond this harness's backing
 * memory (NUM_WORDS default 4096, 32KB, valid up to 0x8000) so the
 * access is guaranteed a cache miss on first touch, forcing a real
 * CACHE_REFILL attempt against wb4_sram that genuinely errors.
 */
module core_bus_fault_cache_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_cache_harness dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    logic halted = 1'b0;
    always @(posedge clk) if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"

    /*
     * Test J's whole point, mirroring core_bus_fault_trap_tb.sv's test F:
     * an AMO read-phase fault must trap immediately, never proceeding
     * into S_AMO_WRITE. Latched globally -- no AMO op in this program
     * ever legitimately reaches S_AMO_WRITE either.
     */
    logic amo_write_entered;
    state_reached_monitor amo_write_monitor (
        .clk(clk), .i_state(dut.core0.state),
        .i_state_target(dut.core0.S_AMO_WRITE), .o_reached(amo_write_entered)
    );

    localparam int unsigned HANDLER_I = 32'h40;
    /*
     * HANDLER_J = 0x54, NOT the word-aligned-looking 0x60 -- Handler I is
     * 5 instructions (odd), so packed back-to-back with Handler J at 2
     * instructions/word starting at word 8 (0x40), Handler J's own first
     * instruction lands mid-word, at 0x54 (word 10's high half), not a
     * fresh word boundary. Got this wrong once already in this file
     * (assumed 0x60 by eyeballing rather than deriving it from the
     * packing loop) -- caught only via a PC trace showing execution
     * jumping to a stale mepc, not by simulation failing cleanly.
     */
    localparam int unsigned HANDLER_J = 32'h54;
    localparam int unsigned RESUME_I  = 32'h14;
    localparam int unsigned RESUME_J  = 32'h2C;
    localparam int unsigned OUT_OF_RANGE = 32'h10000;

    logic [31:0] main_prog[0:12];
    logic [31:0] handler_prog[0:9];
    int i;

    initial begin
        #1;

        /*
         * addr  instr                                    notes
         * 0x00  addi x28, x0, HANDLER_I
         * 0x04  csrrw x0, mtvec, x28
         * 0x08  lui x5, 16                                x5 = 0x10000
         * 0x0C  addi x6, x0, 999                          sentinel dest
         * 0x10  ld x6, 0(x5)                               Test I: load fault
         * 0x14  addi x2, x0, 111                          resume marker I
         * 0x18  addi x28, x0, HANDLER_J
         * 0x1C  csrrw x0, mtvec, x28
         * 0x20  lui x7, 16                                x7 = 0x10000
         * 0x24  addi x8, x0, 5                            rs2 operand
         * 0x28  amoadd.w x9, x8, (x7)                     Test J: AMO read-phase fault
         * 0x2C  addi x3, x0, 222                          resume marker J
         * 0x30  ebreak
         */
        main_prog[0]  = encode_i(int'(HANDLER_I), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[1]  = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[2]  = encode_u(20'h10, 5'd5, `OPC_LUI);
        main_prog[3]  = encode_i(32'sd999, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM);
        main_prog[4]  = encode_i(32'sd0, 5'd5, 3'b011, 5'd6, `OPC_LOAD);
        main_prog[5]  = encode_i(32'sd111, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM);
        main_prog[6]  = encode_i(int'(HANDLER_J), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[7]  = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[8]  = encode_u(20'h10, 5'd7, `OPC_LUI);
        main_prog[9]  = encode_i(32'sd5, 5'd0, 3'b000, 5'd8, `OPC_OP_IMM);
        main_prog[10] = encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd8, 5'd7, `FUNCT3_AMO_W, 5'd9, `OPC_AMO);
        main_prog[11] = encode_i(32'sd222, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM);
        main_prog[12] = encode_i(32'sd1, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM); // ebreak

        for (i = 0; i < 6; i = i + 1)
            dut.sram0.memory[i] = {main_prog[2*i+1], main_prog[2*i]};
        dut.sram0.memory[6][31:0] = main_prog[12]; // 0x30: ebreak, alone in its word's low half

        /*
         * Handler I (0x40) and Handler J (0x54): capture mcause/mtval,
         * mepc <- fixed resume address, mret. Same shape as
         * core_misaligned_trap_tb.sv / core_bus_fault_trap_tb.sv.
         * addr  instr                          | addr  instr
         * 0x40  csrrs x10, mcause, x0    (h0)   | 0x54  csrrs x12, mcause, x0   (h5)
         * 0x44  csrrs x11, mtval, x0     (h1)   | 0x58  csrrs x13, mtval, x0    (h6)
         * 0x48  addi x20, x0, RESUME_I   (h2)   | 0x5C  addi x20, x0, RESUME_J  (h7)
         * 0x4C  csrrw x0, mepc, x20      (h3)   | 0x60  csrrw x0, mepc, x20     (h8)
         * 0x50  mret                     (h4)   | 0x64  mret                    (h9)
         */
        handler_prog[0] = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM);
        handler_prog[1] = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd11, `OPC_SYSTEM);
        handler_prog[2] = encode_i(int'(RESUME_I), 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);
        handler_prog[3] = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[4] = `INSTR_HEX_MRET;
        handler_prog[5] = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd12, `OPC_SYSTEM);
        handler_prog[6] = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd13, `OPC_SYSTEM);
        handler_prog[7] = encode_i(int'(RESUME_J), 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);
        handler_prog[8] = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[9] = `INSTR_HEX_MRET;

        // Packed 2 instructions/word starting at word 8 (0x40) -- see the
        // address table just above for exactly where each one lands.
        for (i = 0; i < 5; i = i + 1)
            dut.sram0.memory[8+i] = {handler_prog[2*i+1], handler_prog[2*i]};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "EBREAK trap never fired");

        // ---- Test I: plain load fault, through the real I$/D$ cache path ----
        check("I: mcause == 5 (load access fault)", dut.core0.regfile0.gp_registers[10], 64'd5);
        check("I: mtval == the faulting load address", dut.core0.regfile0.gp_registers[11], 64'(OUT_OF_RANGE));
        check("I: resumed cleanly", dut.core0.regfile0.gp_registers[2], 64'd111);

        // ---- Test J: AMO read-phase fault, through the real D$ cache path ----
        check("J: mcause == 7 (store/AMO access fault)", dut.core0.regfile0.gp_registers[12], 64'd7);
        check("J: mtval == the faulting AMO address", dut.core0.regfile0.gp_registers[13], 64'(OUT_OF_RANGE));
        check("J: resumed cleanly", dut.core0.regfile0.gp_registers[3], 64'd222);
        check("J: S_AMO_WRITE never entered (cached, paired ack+err must not be mistaken for success)",
            {63'b0, amo_write_entered}, 64'd0);

        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_bus_fault_cache_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_bus_fault_cache_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
