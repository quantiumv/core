// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, Sv39 Milestone 3 -- the fetch-side page-table walker,
 * via core_wb4_sram_harness (flat memory, no cache -- proves walker
 * correctness in isolation, matching every prior milestone's own
 * "isolate then integrate" staging; the real cache-mediated path is
 * Milestone 6's own closing integration test).
 *
 * Every test hand-builds a real 3-level (or shallower, for a superpage)
 * Sv39 page table directly in the harness's own flat SRAM, using
 * riscv_encode.sv's helpers for the M-mode setup program -- no
 * toolchain involved, same idiom core_pmp_tb.sv/core_debug_csr_violation_tb.sv
 * already establish for this class of hand-packed test.
 *
 * Scoped narrower than the staged plan's own original test-list, by
 * explicit, documented decision (matching the PMP milestone's own
 * precedent of shipping fewer tests than first sketched): covers the
 * four highest-risk/most-novel pieces of the design --
 *   A. a real, successful 3-level walk (4KB leaf at level 0) --
 *      end-to-end proof the whole mechanism works at all.
 *   B. a gigapage (leaf found AT LEVEL 2) -- the exact VPN-passthrough
 *      reconstruction this milestone's own design caught a real bug in
 *      during planning (an early draft would have used the PTE's own
 *      zeroed low PPN fields instead of the VA's real vpn1/vpn0,
 *      silently aliasing every address within the superpage onto
 *      offset 0 of the target page).
 *   C. a PTE-content page fault (V=0) -- proves cause 12 classification,
 *      mtval reporting the faulting VIRTUAL address (not the PTE's own
 *      physical address).
 *   D. a PMP-denied PTE read -- proves decision 10's two-tier ordering:
 *      this is cause 1 (access fault, the ORIGINAL access's type), never
 *      cause 12, even though the trigger is discovered mid-walk.
 * Deliberately deferred to a later pass: the dword-crossing independent-
 * HI-walk case, and the remaining individual fault sub-categories
 * (reserved-bits-set, R=0/W=1 malformed, misaligned superpage, U-mode
 * privilege violation, X=0, A=0/Svade, walking past level 0, a
 * noncanonical VA) -- ptw_pte_fault's own OR-list construction makes
 * each of those a cheap, mechanical variation of test C's exact shape,
 * not a new mechanism, so they're lower-value to write by hand right now
 * than they'll be to add later.
 *
 * PTE bit layout used throughout (spec-fixed): V[0] R[1] W[2] X[3] U[4]
 * G[5] A[6] D[7] RSW[9:8] PPN0[18:10] PPN1[27:19] PPN2[53:28].
 */
module core_sv39_fetch_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst;

    localparam logic [2:0] FUNCT3_OR = 3'b110;
    localparam logic [6:0] FUNCT7_OR = 7'b0000000;
    function automatic logic [31:0] enc_or(input logic [4:0] rd, rs1, rs2);
        return encode_r(FUNCT7_OR, rs2, rs1, FUNCT3_OR, rd, `OPC_OP);
    endfunction
    function automatic logic [31:0] enc_addi(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b000, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_slli(input logic [4:0] rd, rs1, input logic [5:0] shamt);
        return encode_shift64(6'b0, shamt, rs1, 3'b001, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_csrrw(input logic [11:0] csr, input logic [4:0] rs1);
        return encode_csr(csr, rs1, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_csrrs(input logic [11:0] csr, input logic [4:0] rd);
        return encode_csr(csr, 5'd0, `FUNCT3_CSRRS, rd, `OPC_SYSTEM);
    endfunction
    localparam logic [31:0] EBREAK_INSN = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM};
    localparam logic [31:0] NOP_INSN    = 32'h00000013;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    /* ----------------------------------------------------------------
     * Test A: basic 4KB page, a real 3-level walk, success.
     * VA = 0x40403000 (vpn2=1, vpn1=2, vpn0=3, offset=0).
     * L2@0x1000 entry1 -> ptr to L1@0x2000; L1@0x2000 entry2 -> ptr to
     * L0@0x3000; L0@0x3000 entry3 -> leaf, PPN=4 (PA 0x4000), RWX=1,U=0.
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_a (.clk(clk), .rst(rst));
    logic halted_a = 1'b0;
    always @(posedge clk) if (dut_a.core0.trap_taken && dut_a.core0.is_ebreak) halted_a <= 1'b1;

    /* ----------------------------------------------------------------
     * Test B: gigapage -- L2@0x1000 entry1 IS the leaf (no L1/L0).
     * VA = 0x40003000 (vpn2=1, vpn1=0, vpn0=3, offset=0), pte.ppn2=0 so
     * the resolved PA stays small: {ppn2=0, va.vpn1=0, va.vpn0=3, off=0}
     * = 0x3000 -- deliberately chosen so the reconstruction depends on
     * va.vpn0 passing through untouched, not merely "happens to be 0".
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_b (.clk(clk), .rst(rst));
    logic halted_b = 1'b0;
    always @(posedge clk) if (dut_b.core0.trap_taken && dut_b.core0.is_ebreak) halted_b <= 1'b1;

    /* ----------------------------------------------------------------
     * Test C: PTE-content page fault (V=0 at the L0 leaf entry).
     * Same page-table shape as test A, but L0 entry3 is left 0 (never
     * written -- V=0 by construction). Real handler at 0x100 captures
     * mcause/mtval before halting.
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_c (.clk(clk), .rst(rst));
    logic halted_c = 1'b0;
    always @(posedge clk) if (dut_c.core0.trap_taken && dut_c.core0.is_ebreak) halted_c <= 1'b1;
    logic [63:0] mcause_c, mtval_c;
    logic        captured_c = 1'b0;
    always @(posedge clk) if (!captured_c && dut_c.core0.commit_now && dut_c.core0.pc == 64'h108) begin
        captured_c <= 1'b1;
        mcause_c   <= dut_c.core0.regfile0.gp_registers[20];
        mtval_c    <= dut_c.core0.regfile0.gp_registers[21];
    end

    /* ----------------------------------------------------------------
     * Test D: PMP-denied PTE read at the L2 level (PA 0x1008, vpn2=1's
     * own entry) -- must classify as cause 1, NOT cause 12, per decision
     * 10 of the staged plan. Same page-table shape as test A/C (L0
     * entry3 IS a real, valid leaf here -- the walk must never even
     * reach it, since the very first PTE read already faults).
     * region0: TOR [0,0x1008), R=1 (permits the M-mode setup code itself
     * and, defensively, anything below the deny window). region1: TOR
     * [0x1008,0x1010), R=0 -- the 8-byte deny window, exactly covering
     * the L2 entry1 PTE. region2: TOR [0x1010, 0x8000), R=1 (permits
     * everything else, defensively, though the walk never reaches it).
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_d (.clk(clk), .rst(rst));
    logic halted_d = 1'b0;
    always @(posedge clk) if (dut_d.core0.trap_taken && dut_d.core0.is_ebreak) halted_d <= 1'b1;
    logic [63:0] mcause_d, mtval_d;
    logic        captured_d = 1'b0;
    always @(posedge clk) if (!captured_d && dut_d.core0.commit_now && dut_d.core0.pc == 64'h108) begin
        captured_d <= 1'b1;
        mcause_d   <= dut_d.core0.regfile0.gp_registers[20];
        mtval_d    <= dut_d.core0.regfile0.gp_registers[21];
    end

    wire halted = halted_a && halted_b && halted_c && halted_d;
    `include "halt_wait.sv"


    initial begin
        rst = 1;
        #1; // run after wb4_sram's own time-0 init

        /*
         * ---- Test A: M-mode setup program, 0x00-0x47 (9 words) ----
         *  0x00 addi x1,x0,8        0x04 slli x1,x1,60        (x1 = satp MODE field)
         *  0x08 addi x2,x0,1        0x0C or   x1,x1,x2         (x2 = L2 PPN=1; x1 = satp)
         *  0x10 csrrw satp,x1       0x14 addi x3,x0,1
         *  0x18 slli x3,x3,11       0x1C csrrw mstatus,x3      (mstatus.MPP = S)
         *  0x20 addi x4,x0,0x404    0x24 slli x4,x4,20         (x4 = VA high part)
         *  0x28 addi x5,x0,3        0x2C slli x5,x5,12         (x5 = VA low part)
         *  0x30 or x4,x4,x5         0x34 csrrw mepc,x4          (x4 = VA = 0x40403000)
         *  0x38 addi x6,x0,0x100    0x3C csrrw mtvec,x6         (defensive fallback handler)
         *  0x40 mret                0x44 nop (pad)
         */
        dut_a.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_a.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_a.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_a.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_a.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)}; // 0x404
        dut_a.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_a.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_a.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)}; // 0x100
        dut_a.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        // Defensive fallback handler @0x100 (word 32): marks x31 if
        // somehow reached, then halts -- test A should NEVER get here.
        dut_a.sram0.memory[32] = {EBREAK_INSN, enc_addi(5'd31,5'd0,1)};
        // Page table: L2@0x1000 (word 512) entry1 -> ptr to L1@0x2000 (PPN=2).
        dut_a.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        // L1@0x2000 (word 1024) entry2 -> ptr to L0@0x3000 (PPN=3).
        dut_a.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        // L0@0x3000 (word 1536) entry3 -> leaf, PPN=4, V=R=W=X=A=D=1,U=0.
        dut_a.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        // Leaf code @0x4000 (word 2048): addi x30,x0,1 ; ebreak.
        dut_a.sram0.memory[2048] = {EBREAK_INSN, enc_addi(5'd30,5'd0,1)};

        /*
         * ---- Test B: identical shape, VA components + L2 entry1 differ ----
         *  0x20 addi x4,x0,1   0x24 slli x4,x4,30   (x4 = 1<<30, vpn2=1 alone)
         *  0x28 addi x5,x0,3   0x2C slli x5,x5,12   (x5 = 3<<12, vpn0=3)
         *  -> VA = 0x40003000 (vpn2=1,vpn1=0,vpn0=3,off=0)
         */
        dut_b.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_b.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_b.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_b.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_b.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd30), enc_addi(5'd4,5'd0,1)};
        dut_b.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_b.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_b.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_b.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_b.sram0.memory[32] = {EBREAK_INSN, enc_addi(5'd31,5'd0,1)};
        // L2@0x1000 (word 512) entry1 -> LEAF directly, ppn=0, V=R=W=X=A=D=1,U=0.
        dut_b.sram0.memory[512 + 1] = 64'h0000_0000_0000_00CF;
        // Leaf code @0x3000 (word 1536): addi x30,x0,1 ; ebreak.
        dut_b.sram0.memory[1536] = {EBREAK_INSN, enc_addi(5'd30,5'd0,1)};

        /*
         * ---- Test C: same shape as test A, but L0 entry3 stays 0
         * (V=0) and the handler @0x100 is the REAL capture handler:
         *  0x100 csrrs x20,mcause,x0   0x104 csrrs x21,mtval,x0
         *  0x108 ebreak
         */
        dut_c.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_c.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_c.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_c.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_c.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_c.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_c.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_c.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_c.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_c.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_c.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};
        dut_c.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801; // L2 entry1 -> L1@0x2000
        dut_c.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01; // L1 entry2 -> L0@0x3000
        // L0 entry3 left 0 (V=0) -- deliberately never written.

        /*
         * ---- Test D: same page-table shape as test A/C (L0 entry3 is
         * a REAL valid leaf -- the walk must never reach it), but PMP
         * denies the L2-level PTE read itself. Same real capture
         * handler as test C.
         */
        dut_d.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_d.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_d.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_d.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        // PMP setup: pmpaddr0=1026(0x1008>>2), pmpaddr1=1028(0x1010>>2),
        // pmpaddr2=0x2000(word units, covers up to byte 0x8000).
        dut_d.sram0.memory[4] = {enc_csrrw(`CSR_PMPADDR0,5'd7), enc_addi(5'd7,5'd0,1026)};
        dut_d.sram0.memory[5] = {enc_csrrw(`CSR_PMPADDR1,5'd8), enc_addi(5'd8,5'd0,1028)};
        dut_d.sram0.memory[6] = {enc_slli(5'd9,5'd9,6'd12), enc_addi(5'd9,5'd0,2)};
        dut_d.sram0.memory[7] = {enc_addi(5'd10,5'd0,9), enc_csrrw(`CSR_PMPADDR2,5'd9)};   // 9 = TOR,R=1
        dut_d.sram0.memory[8] = {enc_slli(5'd11,5'd11,6'd8), enc_addi(5'd11,5'd0,8)};      // 8 = TOR,R=0
        dut_d.sram0.memory[9] = {enc_addi(5'd12,5'd0,9), enc_or(5'd10,5'd10,5'd11)};
        dut_d.sram0.memory[10] = {enc_or(5'd10,5'd10,5'd12), enc_slli(5'd12,5'd12,6'd16)};
        dut_d.sram0.memory[11] = {enc_addi(5'd4,5'd0,1028), enc_csrrw(`CSR_PMPCFG0,5'd10)}; // 0x404
        dut_d.sram0.memory[12] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_d.sram0.memory[13] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_d.sram0.memory[14] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_d.sram0.memory[15] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_d.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_d.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};
        dut_d.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801; // L2 entry1 -> L1@0x2000 (PMP-denied read)
        dut_d.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01; // L1 entry2 -> L0@0x3000
        dut_d.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0 entry3 -> real leaf (never reached)

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "Sv39 fetch walker test never halted");

        // x31 (the fallback-handler marker) is deliberately NOT checked
        // here: this core's own well-documented "terminal ebreak bounces
        // back through an already-armed handler a second time" behavior
        // (mtvec is never disarmed) means x31 can legitimately become 1
        // AFTER halted already latched, harmlessly, on the second pass --
        // a live read of it post-halt has no discriminating power. x30==1
        // already fully proves the real, translated leaf code executed.
        check("A: 4KB page walk succeeded (marker x30==1)", dut_a.core0.regfile0.gp_registers[30], 64'd1);
        check("B: gigapage walk succeeded (marker x30==1)", dut_b.core0.regfile0.gp_registers[30], 64'd1);

        check("C: V=0 PTE produces mcause==12 (instruction page fault)", mcause_c, 64'd12);
        check("C: mtval == the faulting VIRTUAL address", mtval_c, 64'h40403000);

        check("D: PMP-denied PTE read produces mcause==1 (access fault), NOT 12", mcause_d, 64'd1);
        check("D: mtval == the faulting instruction's own VA (not the PTE's PA)", mtval_d, 64'h40403000);

        $display("");
        $display("core_sv39_fetch_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_fetch_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
