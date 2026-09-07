// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, PMP (Physical Memory Protection) enforcement --
 * Milestone 2 of the PMP+PLIC staged plan -- via core_wb4_sram_harness,
 * same real-Wishbone-B4-slave harness core_bus_fault_trap_tb.sv already
 * uses (this file's own direct template).
 *
 * Every denied-access target in tests A/B/C is a real, IN-RANGE address
 * (0x198) with a real pre-seeded sentinel -- deliberately NOT an
 * out-of-range address like core_bus_fault_trap_tb.sv's own 0x1000,
 * because an out-of-range target would let a BROKEN PMP check (denying
 * nothing) still coincidentally trap via wb4_sram.sv's own bounds
 * check, producing the same visible cause code for the wrong reason and
 * masking a real PMP bug. An in-range target instead makes a broken
 * check manifest as "the access silently succeeded" (wrong resume
 * marker, sentinel clobbered), which is what this file's own checks
 * actually discriminate on.
 *
 * Tests A/B/C's own region (region1) MUST be locked (L=1), not just
 * X/W/R=0 -- this was a real, empirically-caught test-design bug, not a
 * hypothetical: per the real PMP spec (norm:pmp_rwx_check), "if L clear
 * and access is M-mode, access succeeds regardless of R/W/X." An
 * unlocked region can NEVER deny an M-mode access, no matter what its
 * own R/W/X bits say -- only a LOCKED region's R/W/X actually govern
 * M-mode. A first draft of this file used L=0 "deny" bytes for region1
 * and got real, confusing failures (fetches/loads/stores all silently
 * SUCCEEDING against a "denied" region) until this was traced back to
 * the RTL correctly implementing the spec and the test being wrong, not
 * the other way around. Because a locked region can never be
 * reconfigured after the fact (norm:pmp_l_bit_write_protection), tests
 * A/B/C deliberately share ONE region (configured once, denying
 * everything) rather than each getting its own differently-configured
 * region the way an unlocked design could -- this also means only 3 of
 * the 4 available regions are used here (region1 for A/B/C, region2 for
 * D, region3 for E), leaving region0 untouched apart from the
 * incidental clearing described below.
 *
 * PMP region0's own permissive reset default is deliberately never
 * relied on here: M-mode's own ordinary program flow is already exempt
 * from PMP whenever NO region matches its own address (the
 * norm:pmp_no_entry_match "M-mode + no match = always succeeds" rule),
 * which holds regardless of region0's own state as long as the ordinary
 * program counter never falls inside one of this file's own configured
 * test regions (all placed at 0x180+, well past the program itself).
 * Every pmpcfg0 write below is therefore a plain full-register CSRRW of
 * just the one test's own region byte(s), not a preserve-and-merge --
 * simpler, and correct precisely because of that same exemption rule.
 * The first such write incidentally clears region0 to A=OFF (its own
 * byte field is 0 in that write's value) -- harmless, since nothing
 * after that point depends on region0 being permissive.
 *
 * Instructions are built into a flat, sequential array in natural
 * program order, then packed into 64-bit SRAM words mechanically (never
 * hand-paired literals) -- same discipline core_bus_fault_trap_tb.sv's
 * own header explains in detail (a real off-by-one this project already
 * got bitten by once, caught only via a PC trace).
 */
module core_pmp_tb;

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

    localparam int unsigned MSTATUS_MPRV_BIT = 17;

    /*
     * Region field encodings, independently transcribed from
     * riscv-isa-manual's own PMP chapter (same discipline as
     * design/csr_file.sv's own header), NOT read from that file's
     * internals: byte = {L, 2'b00, A[1:0], X, W, R}.
     *   region1 (A/B/C): L=1, A=NAPOT, deny everything -- locked, so
     *     M-mode is genuinely denied (see the header comment above).
     *     Configured ONCE; fetch/load/store are all attempted against
     *     the SAME denied region rather than reconfiguring it per test
     *     (a locked region cannot be reconfigured at all).
     *   region2 (D): L=1, A=NAPOT, X=0,W=1,R=1 -- locked, partially
     *     permits (proves the lock enforces the REAL bits, not a
     *     blanket deny).
     *   region3 (E): L=0, A=NAPOT, deny everything -- deliberately left
     *     UNLOCKED, so M-mode stays exempt at MPRV=0 and only the
     *     MPRV=1+MPP=U emulated-U-mode check actually gets denied.
     */
    localparam logic [7:0] PMP1_BYTE_DENY_ALL_LOCKED = 8'b100_11_000; // L=1,X=0,W=0,R=0
    localparam logic [7:0] PMP2_BYTE_LOCKED          = 8'b100_11_011; // L=1,X=0,W=1,R=1
    localparam logic [7:0] PMP3_BYTE_DENY_ALL        = 8'b000_11_000; // L=0,X=0,W=0,R=0

    // Region byte-address targets (word addresses, pmpaddr = byte>>2):
    // region1 @ 0x198 (tests A/B/C), region2 @ 0x180 (test D), region3
    // @ 0x188 (test E) -- all well past this program's own instructions
    // and handlers (which stay below 0x180), all real, in-range 64-bit
    // words under NUM_WORDS=64 (valid byte range [0, 0x200)).
    localparam int unsigned REGION1_ADDR = 32'h198;
    localparam int unsigned REGION2_ADDR = 32'h180;
    localparam int unsigned REGION3_ADDR = 32'h188;
    localparam int unsigned REGION1_PMPADDR = REGION1_ADDR >> 2;
    localparam int unsigned REGION2_PMPADDR = REGION2_ADDR >> 2;
    localparam int unsigned REGION3_PMPADDR = REGION3_ADDR >> 2;

    localparam logic [63:0] SENTINEL_D = 64'hDEAD_BEEF_0000_0180;
    localparam logic [63:0] SENTINEL_E = 64'hCAFE_BABE_0000_0188;
    localparam logic [63:0] SENTINEL_C = 64'hFEED_FACE_0000_0198;

    logic [31:0] main_prog[0:51];
    logic [31:0] handler_prog[0:24];
    int i;
    // Handler addresses are filled in AFTER main_prog is built (derived
    // from a fixed base + index*4, never hand-computed against main_prog
    // itself) -- forward declared here since main_prog's own JAL/ADDI
    // encodings need them. Resume addresses (where each handler's own
    // mret returns to) are plain hex literals inside handler_prog below,
    // hand-verified against main_prog's own real array indices in the
    // per-instruction table comment.
    int unsigned handler_a, handler_b, handler_c, handler_d, handler_e;

    initial begin
        #1; // run after wb4_sram's own time-0 init

        handler_a = 32'h100;           // handlers start at a fixed, known-safe address
                                       // (well past main_prog's own worst-case end,
                                       // well before the 0x180 test-data region),
                                       // 5 instructions each, laid out sequentially.
        handler_b = handler_a + 5*4;
        handler_c = handler_b + 5*4;
        handler_d = handler_c + 5*4;
        handler_e = handler_d + 5*4;

        /*
         * ---- Main program ----
         * idx addr  instr                                    notes
         *  0  0x00  addi x29, x0, REGION1_PMPADDR
         *  1  0x04  csrrw x0, pmpaddr1, x29
         *  2  0x08  addi x29, x0, REGION2_PMPADDR
         *  3  0x0C  csrrw x0, pmpaddr2, x29
         *  4  0x10  addi x29, x0, REGION3_PMPADDR
         *  5  0x14  csrrw x0, pmpaddr3, x29
         *
         * ---- region1 setup: deny everything, LOCKED (once, shared by
         *      tests A/B/C below) ----
         *  6  0x18  addi x28, x0, PMP1_BYTE_DENY_ALL_LOCKED
         *  7  0x1C  slli x28, x28, 8
         *  8  0x20  csrrw x0, pmpcfg0, x28
         *
         * ---- Test A: fetch denied (region1, X=0, locked) ----
         *  9  0x24  addi x28, x0, handler_a
         * 10  0x28  csrrw x0, mtvec, x28
         * 11  0x2C  jal x0, REGION1_ADDR                      attempt fetch there
         * 12  0x30  addi x2, x0, 111                          resume marker A
         *
         * ---- Test B: load denied (region1, R=0, locked) ----
         * 13  0x34  addi x28, x0, handler_b
         * 14  0x38  csrrw x0, mtvec, x28
         * 15  0x3C  addi x29, x0, REGION1_ADDR
         * 16  0x40  addi x21, x0, 901                          sentinel dest
         * 17  0x44  ld x21, 0(x29)                             Test B: load fault
         * 18  0x48  addi x3, x0, 222                           resume marker B
         *
         * ---- Test C: store denied (region1, W=0, locked) ----
         * 19  0x4C  addi x28, x0, handler_c
         * 20  0x50  csrrw x0, mtvec, x28
         * 21  0x54  addi x29, x0, REGION1_ADDR
         * 22  0x58  addi x30, x0, 777                          value to store (irrelevant)
         * 23  0x5C  sd x30, 0(x29)                             Test C: store fault
         * 24  0x60  addi x4, x0, 333                           resume marker C
         *
         * ---- Test D: lock enforcement -- permitted load (R=1) then
         *      denied fetch (X=0), region2, L=1 throughout. This same
         *      write also proves region1's own lock survives an
         *      unrelated later pmpcfg0 write (its byte1 field in this
         *      write's own value is 0, which would clear it if it were
         *      still writable) ----
         * 25  0x64  addi x28, x0, PMP2_BYTE_LOCKED
         * 26  0x68  slli x28, x28, 16
         * 27  0x6C  csrrw x0, pmpcfg0, x28
         * 28  0x70  addi x29, x0, REGION2_ADDR
         * 29  0x74  ld x22, 0(x29)                             D1: succeeds (R=1 permits)
         * 30  0x78  addi x28, x0, handler_d
         * 31  0x7C  csrrw x0, mtvec, x28
         * 32  0x80  jal x0, REGION2_ADDR                       D2: fetch denied (X=0), despite M+locked
         * 33  0x84  addi x5, x0, 444                           resume marker D2
         *
         * ---- Test E: MPRV -- M-mode exempt (MPRV=0), then checked as
         *      U (MPRV=1,MPP=U, denied), then exempt again (MPRV=0).
         *      region3 stays UNLOCKED throughout (see header) ----
         * 34  0x88  addi x28, x0, PMP3_BYTE_DENY_ALL
         * 35  0x8C  slli x28, x28, 24
         * 36  0x90  csrrw x0, pmpcfg0, x28
         * 37  0x94  addi x29, x0, REGION3_ADDR
         * 38  0x98  ld x23, 0(x29)                             E1: MPRV=0 -- succeeds (M-exempt)
         * 39  0x9C  addi x28, x0, 3
         * 40  0xA0  slli x28, x28, 11                          MPP field mask, bits[12:11]
         * 41  0xA4  csrrc x0, mstatus, x28                     clear MPP -> MPP=U(00)
         * 42  0xA8  addi x28, x0, 1
         * 43  0xAC  slli x28, x28, MSTATUS_MPRV_BIT
         * 44  0xB0  csrrs x0, mstatus, x28                     set MPRV=1 (MPP already U)
         * 45  0xB4  addi x28, x0, handler_e
         * 46  0xB8  csrrw x0, mtvec, x28
         * 47  0xBC  ld x24, 0(x29)                             E2: MPRV=1,MPP=U -- denied
         * 48  0xC0  addi x6, x0, 555                           resume marker E2
         * 49  0xC4  addi x28, x0, 1
         * 50  0xC8  slli x28, x28, MSTATUS_MPRV_BIT
         * 51  0xCC  csrrc x0, mstatus, x28                     clear MPRV -- M-exempt again
         *     0xD0  ld x25, 0(x29)                             E3: succeeds again -- see below
         *     0xD4  ebreak
         */
        main_prog[0]  = encode_i(int'(REGION1_PMPADDR), 5'd0, 3'b000, 5'd29, `OPC_OP_IMM);
        main_prog[1]  = encode_csr(`CSR_PMPADDR1, 5'd29, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[2]  = encode_i(int'(REGION2_PMPADDR), 5'd0, 3'b000, 5'd29, `OPC_OP_IMM);
        main_prog[3]  = encode_csr(`CSR_PMPADDR2, 5'd29, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[4]  = encode_i(int'(REGION3_PMPADDR), 5'd0, 3'b000, 5'd29, `OPC_OP_IMM);
        main_prog[5]  = encode_csr(`CSR_PMPADDR3, 5'd29, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);

        main_prog[6]  = encode_i(int'(PMP1_BYTE_DENY_ALL_LOCKED), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[7]  = encode_shift64(6'b000000, 6'd8, 5'd28, 3'b001, 5'd28, `OPC_OP_IMM);
        main_prog[8]  = encode_csr(`CSR_PMPCFG0, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);

        main_prog[9]  = encode_i(int'(handler_a), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[10] = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[11] = encode_j(int'(REGION1_ADDR) - 32'h2C, 5'd0, `OPC_JAL);
        main_prog[12] = encode_i(32'sd111, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM);

        main_prog[13] = encode_i(int'(handler_b), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[14] = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[15] = encode_i(int'(REGION1_ADDR), 5'd0, 3'b000, 5'd29, `OPC_OP_IMM);
        main_prog[16] = encode_i(32'sd901, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM);
        main_prog[17] = encode_i(32'sd0, 5'd29, 3'b011, 5'd21, `OPC_LOAD);
        main_prog[18] = encode_i(32'sd222, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM);

        main_prog[19] = encode_i(int'(handler_c), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[20] = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[21] = encode_i(int'(REGION1_ADDR), 5'd0, 3'b000, 5'd29, `OPC_OP_IMM);
        main_prog[22] = encode_i(32'sd777, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM);
        main_prog[23] = encode_s(32'sd0, 5'd30, 5'd29, 3'b011, `OPC_STORE);
        main_prog[24] = encode_i(32'sd333, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM);

        main_prog[25] = encode_i(int'(PMP2_BYTE_LOCKED), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[26] = encode_shift64(6'b000000, 6'd16, 5'd28, 3'b001, 5'd28, `OPC_OP_IMM);
        main_prog[27] = encode_csr(`CSR_PMPCFG0, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[28] = encode_i(int'(REGION2_ADDR), 5'd0, 3'b000, 5'd29, `OPC_OP_IMM);
        main_prog[29] = encode_i(32'sd0, 5'd29, 3'b011, 5'd22, `OPC_LOAD);
        main_prog[30] = encode_i(int'(handler_d), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[31] = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[32] = encode_j(int'(REGION2_ADDR) - 32'h80, 5'd0, `OPC_JAL);
        main_prog[33] = encode_i(32'sd444, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM);

        main_prog[34] = encode_i(int'(PMP3_BYTE_DENY_ALL), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[35] = encode_shift64(6'b000000, 6'd24, 5'd28, 3'b001, 5'd28, `OPC_OP_IMM);
        main_prog[36] = encode_csr(`CSR_PMPCFG0, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[37] = encode_i(int'(REGION3_ADDR), 5'd0, 3'b000, 5'd29, `OPC_OP_IMM);
        main_prog[38] = encode_i(32'sd0, 5'd29, 3'b011, 5'd23, `OPC_LOAD);
        main_prog[39] = encode_i(32'sd3, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[40] = encode_shift64(6'b000000, 6'd11, 5'd28, 3'b001, 5'd28, `OPC_OP_IMM);
        main_prog[41] = encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRC, 5'd0, `OPC_SYSTEM);
        main_prog[42] = encode_i(32'sd1, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[43] = encode_shift64(6'b000000, 6'(MSTATUS_MPRV_BIT), 5'd28, 3'b001, 5'd28, `OPC_OP_IMM);
        main_prog[44] = encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRS, 5'd0, `OPC_SYSTEM);
        main_prog[45] = encode_i(int'(handler_e), 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[46] = encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        main_prog[47] = encode_i(32'sd0, 5'd29, 3'b011, 5'd24, `OPC_LOAD);
        main_prog[48] = encode_i(32'sd555, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM);
        main_prog[49] = encode_i(32'sd1, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM);
        main_prog[50] = encode_shift64(6'b000000, 6'(MSTATUS_MPRV_BIT), 5'd28, 3'b001, 5'd28, `OPC_OP_IMM);
        main_prog[51] = encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRC, 5'd0, `OPC_SYSTEM);

        for (i = 0; i < 26; i = i + 1)
            dut.sram0.memory[i] = {main_prog[2*i+1], main_prog[2*i]};
        // main_prog has 52 entries (0-51, an even count) -- the loop
        // above (26 iterations, 2 entries each) packs all of them into
        // memory[0..25]. memory[26] (byte range 0xD0-0xD7) holds the two
        // real instructions immediately following the array in program
        // order: idx 52 (0xD0) ld x25,0(x29) -- E3, confirms access
        // succeeds again once MPRV is cleared; idx 53 (0xD4) ebreak.
        dut.sram0.memory[26] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM),  // ebreak
                                 encode_i(32'sd0, 5'd29, 3'b011, 5'd25, `OPC_LOAD)}; // ld x25,0(x29)

        /*
         * ---- Handlers, 5 instructions each ----
         * Every handler: csrrs <causeReg>, mcause, x0; csrrs <valReg>,
         * mtval, x0; addi x20, x0, <resume>; csrrw mepc, x20; mret.
         */
        handler_prog[0]  = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd9, `OPC_SYSTEM);
        handler_prog[1]  = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM);
        handler_prog[2]  = encode_i(32'h30, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);   // RESUME_A = idx 12*4 = 0x30
        handler_prog[3]  = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[4]  = `INSTR_HEX_MRET;

        handler_prog[5]  = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd11, `OPC_SYSTEM);
        handler_prog[6]  = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd12, `OPC_SYSTEM);
        handler_prog[7]  = encode_i(32'h48, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);   // RESUME_B = idx 18*4 = 0x48
        handler_prog[8]  = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[9]  = `INSTR_HEX_MRET;

        handler_prog[10] = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd13, `OPC_SYSTEM);
        handler_prog[11] = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd14, `OPC_SYSTEM);
        handler_prog[12] = encode_i(32'h60, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);   // RESUME_C = idx 24*4 = 0x60
        handler_prog[13] = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[14] = `INSTR_HEX_MRET;

        handler_prog[15] = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd15, `OPC_SYSTEM);
        handler_prog[16] = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd16, `OPC_SYSTEM);
        handler_prog[17] = encode_i(32'h84, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);   // RESUME_D2 = idx 33*4 = 0x84
        handler_prog[18] = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[19] = `INSTR_HEX_MRET;

        handler_prog[20] = encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd17, `OPC_SYSTEM);
        handler_prog[21] = encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd18, `OPC_SYSTEM);
        handler_prog[22] = encode_i(32'hC0, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM);   // RESUME_E2 = idx 48*4 = 0xC0
        handler_prog[23] = encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
        handler_prog[24] = `INSTR_HEX_MRET;

        for (i = 0; i < 12; i = i + 1)
            dut.sram0.memory[(handler_a/8)+i] = {handler_prog[2*i+1], handler_prog[2*i]};
        // handler_prog has 25 entries (0-24, odd count) -- the loop above
        // (12 iterations = 24 entries) covers all but the last (mret for
        // handler E); write it alone, paired with a following NOP-shaped
        // don't-care high half (never executed -- mret doesn't fall
        // through, and nothing else is placed at that address).
        dut.sram0.memory[(handler_a/8)+12] = {32'h0000_0013, handler_prog[24]};

        // Real sentinels at the three test regions, confirmed
        // independently: D1/E1/E3 must read these EXACT values back;
        // test C's own store must leave its own sentinel untouched.
        dut.sram0.memory[REGION2_ADDR/8] = SENTINEL_D;
        dut.sram0.memory[REGION3_ADDR/8] = SENTINEL_E;
        dut.sram0.memory[REGION1_ADDR/8] = SENTINEL_C;

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "EBREAK trap never fired");

        // ---- Test A: fetch denied (X=0, locked) ----
        check("A: mcause == 1 (instruction access fault)", dut.core0.regfile0.gp_registers[9], 64'd1);
        check("A: mtval == mepc == the denied fetch address", dut.core0.regfile0.gp_registers[10], 64'(REGION1_ADDR));
        check("A: resumed cleanly", dut.core0.regfile0.gp_registers[2], 64'd111);

        // ---- Test B: load denied (R=0, locked) ----
        check("B: mcause == 5 (load access fault)", dut.core0.regfile0.gp_registers[11], 64'd5);
        check("B: mtval == the denied load address", dut.core0.regfile0.gp_registers[12], 64'(REGION1_ADDR));
        check("B: dest register untouched (load never happened)", dut.core0.regfile0.gp_registers[21], 64'd901);
        check("B: resumed cleanly", dut.core0.regfile0.gp_registers[3], 64'd222);

        // ---- Test C: store denied (W=0, locked) ----
        check("C: mcause == 7 (store/AMO access fault)", dut.core0.regfile0.gp_registers[13], 64'd7);
        check("C: mtval == the denied store address", dut.core0.regfile0.gp_registers[14], 64'(REGION1_ADDR));
        check("C: resumed cleanly", dut.core0.regfile0.gp_registers[4], 64'd333);
        check("C: sentinel at the denied store address unchanged", dut.sram0.memory[REGION1_ADDR/8], SENTINEL_C);

        // ---- Test D: lock enforcement ----
        check("D1: locked region's own R=1 still permits a real load", dut.core0.regfile0.gp_registers[22], SENTINEL_D);
        check("D2: mcause == 1 (fetch denied, X=0, despite M-mode + locked)",
            dut.core0.regfile0.gp_registers[15], 64'd1);
        check("D2: mtval == mepc == the denied fetch address", dut.core0.regfile0.gp_registers[16], 64'(REGION2_ADDR));
        check("D2: resumed cleanly", dut.core0.regfile0.gp_registers[5], 64'd444);

        // ---- Test E: MPRV-aware effective privilege ----
        check("E1: MPRV=0 -- M-mode exempt, real load succeeds", dut.core0.regfile0.gp_registers[23], SENTINEL_E);
        check("E2: mcause == 5 (MPRV=1,MPP=U -- checked as U, denied)",
            dut.core0.regfile0.gp_registers[17], 64'd5);
        check("E2: mtval == the denied load address", dut.core0.regfile0.gp_registers[18], 64'(REGION3_ADDR));
        check("E2: resumed cleanly", dut.core0.regfile0.gp_registers[6], 64'd555);
        check("E3: MPRV cleared -- M-mode exempt again, real load succeeds", dut.core0.regfile0.gp_registers[25], SENTINEL_E);

        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_pmp_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_pmp_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
