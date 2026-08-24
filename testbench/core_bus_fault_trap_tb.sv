// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, six independent bus-error traps (instruction/load/
 * store/AMO access faults, causes 1/5/7) genuinely trapping through the
 * real core, via core_wb4_sram_harness -- wb4_sram.sv is the one real
 * Wishbone-B4-compliant slave in this project (ack/err mutually
 * exclusive, an out-of-range access sets err_o with ack_o held 0), so
 * this harness is what actually exercises wb_done/wb_ok's necessity --
 * see design/core.sv's own header comment on wb_done/wb_ok for why bare
 * wb_ack_i is ambiguous through the CACHED path but not through this one.
 *
 * NUM_WORDS=64 (a power of 2, matching wb4_sram.sv's own $clog2-based
 * addr_valid check exactly -- a non-power-of-2 size leaves a gap between
 * addr_valid's rounded-up boundary and the real array bound, which is
 * not what these tests want to exercise) -- valid range is byte
 * addresses [0, 0x200). 0x1000 is the shared "out of range" target for
 * every test except B, which needs a specific boundary (see its own
 * comment below).
 *
 * All six tests use mtvec re-pointed to a dedicated handler (same
 * pattern as core_misaligned_trap_tb.sv), each handler capturing
 * mcause/mtval into test-specific registers, then setting mepc to a
 * fixed, hardcoded resume address and mret-ing there (simpler than
 * computing mepc+instruction-length, and works uniformly for every
 * cause here since none of them have a "faulting instruction to skip
 * past" in the same sense a synchronous ALU-instruction trap would --
 * the faulted bus cycle already prevented any real effect).
 *
 * Instructions are built into flat, sequential arrays (main_prog/
 * handler_prog) in natural program order, then packed into 64-bit SRAM
 * words by a plain loop -- deliberately NOT hand-paired `memory[N] =
 * {instrB, instrA}` literals one at a time: an earlier version of this
 * file did exactly that and got a word-index off-by-one partway through
 * (easy to make, since every pair requires manually tracking which half
 * is high/low AND which word index you're currently on), which iverilog
 * happily compiled and even partially "ran" -- caught only by a PC trace
 * showing execution reaching an unintended address, not by any static
 * check. Packing mechanically removes that whole class of mistake.
 */
module core_bus_fault_trap_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_wb4_sram_harness #(.NUM_WORDS(64)) dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    logic halted = 1'b0;
    always @(posedge clk) if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"

    /*
     * Test F's whole point: an AMO read-phase fault must trap immediately
     * from S_MEM, never proceeding into S_AMO_WRITE to issue a bogus
     * second (write) bus transaction. Latched globally (not scoped to
     * test F's own window) since no other AMO op in this program ever
     * legitimately reaches S_AMO_WRITE either (LR is not is_amo_rmw, and
     * the one real AMOADD here is the one under test) -- a true positive
     * anywhere in the whole run is equally damning.
     */
    logic amo_write_entered;
    state_reached_monitor amo_write_monitor (
        .clk(clk), .i_state(dut.core0.state),
        .i_state_target(dut.core0.S_AMO_WRITE), .o_reached(amo_write_entered)
    );

    /* Register allocation (all distinct, checked independently at the end):
     *   x2-x7:   resume markers, one per test (A-F), prove clean resume.
     *   x8/x9:   mcause/mtval, test A (instruction fetch fault).
     *   x10/x11: mcause/mtval, test B (dword-crossing fetch-hi fault).
     *   x12/x13: mcause/mtval, test C (plain load fault).
     *   x14/x15: mcause/mtval, test D (plain store fault).
     *   x16/x17: mcause/mtval, test E (LR.W fault).
     *   x18/x19: mcause/mtval, test F (AMO read-phase fault).
     *   x20:     scratch, resume-address temp, reused by every handler.
     *   x21:     test C's LD destination -- must stay at its sentinel
     *            value (901), proving the faulted load never wrote it.
     *   x22:     test E's LR destination -- same role, sentinel 902.
     *   x23:     test F's AMO destination -- same role, sentinel 903.
     *   x24:     test F's AMOADD rs2 operand (5) -- irrelevant, the op
     *            never completes.
     *   x28:     scratch, mtvec target, reused by every test setup.
     *   x29/x30: scratch, out-of-range address / store value, reused.
     */
    localparam int unsigned HANDLER_A = 32'h88;
    localparam int unsigned HANDLER_B = 32'h9C;
    localparam int unsigned HANDLER_C = 32'hB0;
    localparam int unsigned HANDLER_D = 32'hC4;
    localparam int unsigned HANDLER_E = 32'hD8;
    localparam int unsigned HANDLER_F = 32'hEC;

    localparam int unsigned RESUME_A = 32'h0C;
    localparam int unsigned RESUME_B = 32'h1C;
    localparam int unsigned RESUME_C = 32'h34;
    localparam int unsigned RESUME_D = 32'h4C;
    localparam int unsigned RESUME_E = 32'h64;
    localparam int unsigned RESUME_F = 32'h80;

    localparam int unsigned OUT_OF_RANGE = 32'h1000;

    /*
     * Test B: the crossing instruction starts at 0x1FE (pc[2:1]==2'b11,
     * the last halfword slot of the dword at 0x1F8 -- the LAST valid
     * dword under NUM_WORDS=64, whose own fetch (S_FETCH) succeeds), so
     * its upper 16 bits would need to come from the dword at 0x200 --
     * one past the valid range, so S_FETCH_HI genuinely faults. Directly
     * proves fetch_fault_q's trap_val is `pc` unconditionally (mepc==
     * mtval==0x1FE, the crossing instruction's own address), not
     * something that needs to know whether S_FETCH or S_FETCH_HI was
     * the half that actually faulted.
     */
    localparam int unsigned TEST_B_TARGET = 32'h1FE;

    logic [31:0] main_prog[0:33];
    logic [31:0] handler_prog[0:29];
    int i;

    initial begin
        #1; // run after wb4_sram's own time-0 init

        /*
         * ---- Main program, 34 instructions, addr 0x00-0x87 ----
         * idx  addr  instr                                  notes
         *  0   0x00  addi x28, x0, HANDLER_A
         *  1   0x04  csrrw x0, mtvec, x28
         *  2   0x08  jal x0, OUT_OF_RANGE                    Test A: fetch fault
         *  3   0x0C  addi x2, x0, 111                        resume marker A
         *  4   0x10  addi x28, x0, HANDLER_B
         *  5   0x14  csrrw x0, mtvec, x28
         *  6   0x18  jal x0, TEST_B_TARGET                   Test B: fetch-hi fault
         *  7   0x1C  addi x3, x0, 222                        resume marker B
         *  8   0x20  addi x28, x0, HANDLER_C
         *  9   0x24  csrrw x0, mtvec, x28
         * 10   0x28  lui x29, 1                              x29 = 0x1000
         * 11   0x2C  addi x21, x0, 901                       sentinel dest
         * 12   0x30  ld x21, 0(x29)                          Test C: load fault
         * 13   0x34  addi x4, x0, 333                        resume marker C
         * 14   0x38  addi x28, x0, HANDLER_D
         * 15   0x3C  csrrw x0, mtvec, x28
         * 16   0x40  lui x29, 1
         * 17   0x44  addi x30, x0, 777                       value to store (irrelevant)
         * 18   0x48  sd x30, 0(x29)                          Test D: store fault
         * 19   0x4C  addi x5, x0, 444                        resume marker D
         * 20   0x50  addi x28, x0, HANDLER_E
         * 21   0x54  csrrw x0, mtvec, x28
         * 22   0x58  lui x29, 1
         * 23   0x5C  addi x22, x0, 902                       sentinel dest
         * 24   0x60  lr.w x22, (x29)                         Test E: LR fault
         * 25   0x64  addi x6, x0, 555                        resume marker E
         * 26   0x68  addi x28, x0, HANDLER_F
         * 27   0x6C  csrrw x0, mtvec, x28
         * 28   0x70  lui x29, 1
         * 29   0x74  addi x23, x0, 903                       sentinel dest
         * 30   0x78  addi x24, x0, 5                         rs2 operand (irrelevant)
         * 31   0x7C  amoadd.w x23, x24, (x29)                Test F: AMO read-phase fault
         * 32   0x80  addi x7, x0, 666                        resume marker F
         * 33   0x84  ebreak
         */
        main_prog[0]  = encode_i(int'(HANDLER_A), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[1]  = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[2]  = encode_j(int'(OUT_OF_RANGE) - 32'h08, 5'd0, `OPC_JAL);
        main_prog[3]  = encode_i(32'sd111, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM);
        main_prog[4]  = encode_i(int'(HANDLER_B), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[5]  = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[6]  = encode_j(int'(TEST_B_TARGET) - 32'h18, 5'd0, `OPC_JAL);
        main_prog[7]  = encode_i(32'sd222, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM);
        main_prog[8]  = encode_i(int'(HANDLER_C), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[9]  = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[10] = encode_u(20'h1, 5'd29, `OPC_LUI);
        main_prog[11] = encode_i(32'sd901, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM);
        main_prog[12] = encode_i(32'sd0, 5'd29, 3'b011, 5'd21, `OPC_LOAD);
        main_prog[13] = encode_i(32'sd333, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM);
        main_prog[14] = encode_i(int'(HANDLER_D), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[15] = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[16] = encode_u(20'h1, 5'd29, `OPC_LUI);
        main_prog[17] = encode_i(32'sd777, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM);
        main_prog[18] = encode_s(32'sd0, 5'd30, 5'd29, 3'b011, `OPC_STORE);
        main_prog[19] = encode_i(32'sd444, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM);
        main_prog[20] = encode_i(int'(HANDLER_E), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[21] = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[22] = encode_u(20'h1, 5'd29, `OPC_LUI);
        main_prog[23] = encode_i(32'sd902, 5'd0, 3'b000, 5'd22, `OPC_OP_IMM);
        main_prog[24] = encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0, 5'd29, `FUNCT3_AMO_W, 5'd22, `OPC_AMO);
        main_prog[25] = encode_i(32'sd555, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM);
        main_prog[26] = encode_i(int'(HANDLER_F), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[27] = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[28] = encode_u(20'h1, 5'd29, `OPC_LUI);
        main_prog[29] = encode_i(32'sd903, 5'd0, 3'b000, 5'd23, `OPC_OP_IMM);
        main_prog[30] = encode_i(32'sd5, 5'd0, 3'b000, 5'd24, `OPC_OP_IMM);
        main_prog[31] = encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd24, 5'd29, `FUNCT3_AMO_W, 5'd23, `OPC_AMO);
        main_prog[32] = encode_i(32'sd666, 5'd0, 3'b000, 5'd7, `OPC_OP_IMM);
        main_prog[33] = encode_i(32'sd1, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM); // ebreak

        for (i = 0; i < 17; i = i + 1)
            dut.sram0.memory[i] = {main_prog[2*i+1], main_prog[2*i]};

        /*
         * ---- Handlers, 5 instructions each, addr 0x88-0xFF ----
         * Every handler: csrrs mcause, csrrs mtval, addi x20 (resume
         * addr), csrrw mepc x20, mret. h_idx = global index 0-29 across
         * all six handlers; address = 0x88 + h_idx*4.
         */
        handler_prog[0]  = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd8, `OPC_SYSTEM);   // A
        handler_prog[1]  = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd9, `OPC_SYSTEM);
        handler_prog[2]  = encode_i(int'(RESUME_A), 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);
        handler_prog[3]  = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[4]  = `INSTR_HEX_MRET;
        handler_prog[5]  = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM);  // B
        handler_prog[6]  = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd11, `OPC_SYSTEM);
        handler_prog[7]  = encode_i(int'(RESUME_B), 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);
        handler_prog[8]  = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[9]  = `INSTR_HEX_MRET;
        handler_prog[10] = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd12, `OPC_SYSTEM);  // C
        handler_prog[11] = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd13, `OPC_SYSTEM);
        handler_prog[12] = encode_i(int'(RESUME_C), 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);
        handler_prog[13] = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[14] = `INSTR_HEX_MRET;
        handler_prog[15] = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd14, `OPC_SYSTEM);  // D
        handler_prog[16] = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd15, `OPC_SYSTEM);
        handler_prog[17] = encode_i(int'(RESUME_D), 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);
        handler_prog[18] = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[19] = `INSTR_HEX_MRET;
        handler_prog[20] = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd16, `OPC_SYSTEM);  // E
        handler_prog[21] = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd17, `OPC_SYSTEM);
        handler_prog[22] = encode_i(int'(RESUME_E), 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);
        handler_prog[23] = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[24] = `INSTR_HEX_MRET;
        handler_prog[25] = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd18, `OPC_SYSTEM);  // F
        handler_prog[26] = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd19, `OPC_SYSTEM);
        handler_prog[27] = encode_i(int'(RESUME_F), 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);
        handler_prog[28] = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[29] = `INSTR_HEX_MRET;

        for (i = 0; i < 15; i = i + 1)
            dut.sram0.memory[17+i] = {handler_prog[2*i+1], handler_prog[2*i]};

        /*
         * Test D's "store never landed" defense-in-depth check: a nearby
         * valid word, never touched by any real instruction in this
         * program. Structurally this can never actually be corrupted
         * (wb4_sram.sv's own addr_valid gate keeps an out-of-range write
         * from ever reaching `memory[]` at all, regardless of whether
         * core.sv's fault handling is correct), but checking it directly
         * still proves core.sv's own fault path doesn't accidentally
         * compute or drive a DIFFERENT, valid address as a side effect.
         */
        dut.sram0.memory[40] = 64'hCAFE_F00D_CAFE_F00D;

        /*
         * Test B's crossing dword: hw3 (bits[63:48], the halfword at
         * offset 6 -- pc[2:1]==2'b11 selects it as "first_hw") holds the
         * low 16 bits of an ordinary 32-bit opcode (0x0013, ADDI's own
         * low halfword -- bits[1:0]==2'b11, which is what actually
         * signals "this is the start of an uncompressed instruction" to
         * fetch_hi_needed/is_compressed; the fetch never reaches decode
         * at all, so which real instruction this would have been is
         * irrelevant). The other three halfwords are never selected at
         * this pc and are left zero.
         */
        dut.sram0.memory[63] = {16'h0013, 16'h0000, 16'h0000, 16'h0000};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "EBREAK trap never fired");

        // ---- Test A: instruction fetch fault ----
        check("A: mcause == 1 (instruction access fault)", dut.core0.regfile0.gp_registers[8], 64'd1);
        check("A: mtval == mepc == faulting fetch address", dut.core0.regfile0.gp_registers[9], 64'h1000);
        check("A: resumed cleanly", dut.core0.regfile0.gp_registers[2], 64'd111);

        // ---- Test B: dword-crossing fetch-hi fault ----
        check("B: mcause == 1 (instruction access fault)", dut.core0.regfile0.gp_registers[10], 64'd1);
        check("B: mtval == mepc == the crossing instruction's own address (not the failed S_FETCH_HI address)",
            dut.core0.regfile0.gp_registers[11], 64'h1FE);
        check("B: resumed cleanly", dut.core0.regfile0.gp_registers[3], 64'd222);

        // ---- Test C: plain load fault ----
        check("C: mcause == 5 (load access fault)", dut.core0.regfile0.gp_registers[12], 64'd5);
        check("C: mtval == the faulting load address", dut.core0.regfile0.gp_registers[13], 64'h1000);
        check("C: dest register untouched (load never happened)", dut.core0.regfile0.gp_registers[21], 64'd901);
        check("C: resumed cleanly", dut.core0.regfile0.gp_registers[4], 64'd333);

        // ---- Test D: plain store fault ----
        check("D: mcause == 7 (store/AMO access fault)", dut.core0.regfile0.gp_registers[14], 64'd7);
        check("D: mtval == the faulting store address", dut.core0.regfile0.gp_registers[15], 64'h1000);
        check("D: resumed cleanly", dut.core0.regfile0.gp_registers[5], 64'd444);
        check("D: nearby valid sentinel dword unchanged", dut.sram0.memory[40], 64'hCAFE_F00D_CAFE_F00D);

        // ---- Test E: LR.W fault -- must classify as cause 7, not 5 ----
        check("E: mcause == 7 (store/AMO access fault, NOT 5 -- LR is spec-classified as store/AMO)",
            dut.core0.regfile0.gp_registers[16], 64'd7);
        check("E: mtval == the faulting LR address", dut.core0.regfile0.gp_registers[17], 64'h1000);
        check("E: dest register untouched (LR never happened)", dut.core0.regfile0.gp_registers[22], 64'd902);
        check("E: resumed cleanly", dut.core0.regfile0.gp_registers[6], 64'd555);

        // ---- Test F: AMO read-phase fault ----
        check("F: mcause == 7 (store/AMO access fault)", dut.core0.regfile0.gp_registers[18], 64'd7);
        check("F: mtval == the faulting AMO address", dut.core0.regfile0.gp_registers[19], 64'h1000);
        check("F: dest register untouched (AMO never happened)", dut.core0.regfile0.gp_registers[23], 64'd903);
        check("F: resumed cleanly", dut.core0.regfile0.gp_registers[7], 64'd666);
        check("F: S_AMO_WRITE never entered (read-phase fault must not chase a bogus write)",
            {63'b0, amo_write_entered}, 64'd0);

        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_bus_fault_trap_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_bus_fault_trap_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
