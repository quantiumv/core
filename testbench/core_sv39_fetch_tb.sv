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
 * Originally deferred, later closed by a directed post-plan coverage
 * pass (adversarial-audit follow-up): the remaining individual
 * malformed/A-D/noncanonical fault sub-categories on the FETCH stream --
 * each a cheap, mechanical variation of test C's exact shape, reusing
 * its own page-table/handler pattern verbatim:
 *   F. PBMT[62:61] set alone (malformed) -- distinguished from N/reserved.
 *   G. N[63] set alone (malformed).
 *   H. reserved[60:54] set alone (malformed).
 *   I. A=0 on a FETCH-stream leaf specifically (Svade, cause 12).
 *   J/K. a noncanonical VA, two independent patterns (an extra high bit
 *      set above bit38; bit38 itself set with the rest of the upper
 *      bits clear) -- both re-walk a table that IS otherwise real and
 *      valid, so a missing/buggy canonical check would show up as a
 *      spurious SUCCESS, not merely an untested code path.
 * (U-mode privilege violation on the FETCH stream is already exercised
 * indirectly by core_sv39_tlb_tb.sv's own U=0 page-table construction;
 * R=0/W=1 malformed, walking past level 0, and X=0 remain mechanical
 * variations of test C's same shape, still deliberately deferred as
 * genuinely lower-value.)
 *
 *   E. the dword-crossing independent-HI-walk case, under active
 *      translation, with the LO and HI halves in DIFFERENT PMP regions --
 *      the regression proof for a real bug found post-Milestone-6 by an
 *      independent adversarial re-review of the completed Sv39 work:
 *      pmp_fetchhi_fault used to be checked against fetch_hi_paddr_q
 *      BEFORE that register had ever resolved for the current
 *      instruction (it held whatever the PREVIOUS crossing fetch left
 *      there -- the register has no reset). A first crossing instruction
 *      whose own HI half is genuinely PMP-denied correctly faults
 *      (proving decision 10's PMP-after-translation ordering extends to
 *      the fetch-HI stream, not just LO/mem); a SECOND, unrelated
 *      crossing instruction whose own HI half is genuinely PMP-PERMITTED
 *      must still execute correctly afterward -- under the bug, it would
 *      have spuriously faulted too, since the stale (denied) address
 *      left over from the FIRST instruction was checked before the
 *      second instruction's own real address was ever resolved.
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

    /* ----------------------------------------------------------------
     * Test E: dword-crossing fetch under translation, instruction 1's
     * HI half PMP-denied, instruction 2's HI half PMP-permitted -- see
     * this file's own header comment for what this proves.
     *
     * PMP: a SINGLE, generous region0 = TOR[0, 0x9000) R+X. Deliberately
     * NOT a tight boundary immediately after instruction 1's own HI
     * half: fetch_end_paddr/fetch_hi_end_paddr (core.sv) are computed as
     * fetch_paddr(_hi) + 7 WITHOUT dword-truncating fetch_paddr(_hi)
     * first -- a real, pre-existing, unrelated-to-Sv39 conservatism in
     * the original PMP milestone's own fetch-side region matching
     * (documented there as deliberate: checking the real, eventual dword
     * footprint before decode has run rather than predicting instruction
     * length). Discovered empirically while building this exact test:
     * a TIGHT boundary placed right after a compressed instruction's own
     * dword caused an UNRELATED, pre-existing false denial having
     * nothing to do with the pmp_fetchhi_fault bug this test exists to
     * catch. Region0's own generous size absorbs that conservatism
     * harmlessly for every "should succeed" address in this test,
     * without touching that separate, out-of-scope mechanism.
     *
     * Instruction 1: LOW half's own dword is the LAST dword of page
     * vpn0=7 (VA 0x40407000, PA 0x7000); its HI half (fetch_hi_vaddr =
     * pc+8) lands in a DIFFERENT page, vpn0=8 (VA 0x40408000, PA
     * 0x9000) -- a real, VALID leaf PTE (so this is a PMP denial, cause
     * 1, NOT a page fault, cause 12), but PA 0x9000 sits exactly at
     * region0's own exclusive upper bound -- outside it, hence denied
     * by the S-mode no-match-denies fallback (no second, explicit deny
     * region needed at all).
     *
     * Instruction 2: an ordinary, entirely WITHIN-one-page crossing at
     * vpn0=3 (VA 0x40403000, PA 0x4000, comfortably inside region0) --
     * reached via the trap handler's own mret after instruction 1
     * faults. Must execute cleanly; under the bug this test regresses,
     * it would ALSO have spuriously faulted, since the FSM's decision
     * to even enter S_FETCH_HI for instruction 2 would have checked
     * instruction 1's own stale, denied fetch_hi_paddr_q first.
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(8192)) dut_e (.clk(clk), .rst(rst));
    logic halted_e = 1'b0;
    always @(posedge clk) if (dut_e.core0.trap_taken && dut_e.core0.is_ebreak) halted_e <= 1'b1;
    logic [63:0] mcause_e, mtval_e;
    logic        captured_e = 1'b0;
    always @(posedge clk) if (!captured_e && dut_e.core0.commit_now && dut_e.core0.pc == 64'h108) begin
        captured_e <= 1'b1;
        mcause_e   <= dut_e.core0.regfile0.gp_registers[20];
        mtval_e    <= dut_e.core0.regfile0.gp_registers[21];
    end

    /* ----------------------------------------------------------------
     * Tests F/G/H: ptw_pte_malformed's three independent OR-arms above
     * V (already covered by test C) -- PBMT[62:61], N[63], and
     * reserved[60:54] -- each set ALONE against an otherwise-fully-valid
     * leaf (V=R=W=X=A=D=1, PPN=4, same shape as test A's own real leaf),
     * so a bug that dropped one arm from the OR (or conflated it with
     * another) would show up as a spurious SUCCESS (leaf code reached)
     * instead of the required cause-12 page fault. Same page-table
     * shape/M-mode-setup/real capture handler as test C throughout --
     * only L0 entry3's own PTE differs per test.
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_f (.clk(clk), .rst(rst));
    logic halted_f = 1'b0;
    always @(posedge clk) if (dut_f.core0.trap_taken && dut_f.core0.is_ebreak) halted_f <= 1'b1;
    logic [63:0] mcause_f, mtval_f;
    logic        captured_f = 1'b0;
    always @(posedge clk) if (!captured_f && dut_f.core0.commit_now && dut_f.core0.pc == 64'h108) begin
        captured_f <= 1'b1;
        mcause_f   <= dut_f.core0.regfile0.gp_registers[20];
        mtval_f    <= dut_f.core0.regfile0.gp_registers[21];
    end

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_g (.clk(clk), .rst(rst));
    logic halted_g = 1'b0;
    always @(posedge clk) if (dut_g.core0.trap_taken && dut_g.core0.is_ebreak) halted_g <= 1'b1;
    logic [63:0] mcause_g, mtval_g;
    logic        captured_g = 1'b0;
    always @(posedge clk) if (!captured_g && dut_g.core0.commit_now && dut_g.core0.pc == 64'h108) begin
        captured_g <= 1'b1;
        mcause_g   <= dut_g.core0.regfile0.gp_registers[20];
        mtval_g    <= dut_g.core0.regfile0.gp_registers[21];
    end

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_h (.clk(clk), .rst(rst));
    logic halted_h = 1'b0;
    always @(posedge clk) if (dut_h.core0.trap_taken && dut_h.core0.is_ebreak) halted_h <= 1'b1;
    logic [63:0] mcause_h, mtval_h;
    logic        captured_h = 1'b0;
    always @(posedge clk) if (!captured_h && dut_h.core0.commit_now && dut_h.core0.pc == 64'h108) begin
        captured_h <= 1'b1;
        mcause_h   <= dut_h.core0.regfile0.gp_registers[20];
        mtval_h    <= dut_h.core0.regfile0.gp_registers[21];
    end

    /* ----------------------------------------------------------------
     * Test I: A=0 on a FETCH-stream leaf specifically (V=R=W=X=D=1,
     * A=0) -- proves ptw_ad_fault's own !ptw_pte_a arm fires for fetch
     * too, independent of the mem-only D-check half of that same
     * expression (D stays don't-care/1 here on purpose, so a bug that
     * conflated the two conditions can't hide behind a coincidentally-
     * also-failing D check).
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_i (.clk(clk), .rst(rst));
    logic halted_i = 1'b0;
    always @(posedge clk) if (dut_i.core0.trap_taken && dut_i.core0.is_ebreak) halted_i <= 1'b1;
    logic [63:0] mcause_i, mtval_i;
    logic        captured_i = 1'b0;
    always @(posedge clk) if (!captured_i && dut_i.core0.commit_now && dut_i.core0.pc == 64'h108) begin
        captured_i <= 1'b1;
        mcause_i   <= dut_i.core0.regfile0.gp_registers[20];
        mtval_i    <= dut_i.core0.regfile0.gp_registers[21];
    end

    /* ----------------------------------------------------------------
     * Test J: noncanonical VA, variant 1 -- an extra high bit (bit40)
     * set beyond bit38, while the VA's own low 39 bits are IDENTICAL to
     * test A's real, fully valid mapping (vpn2=1,vpn1=2,vpn0=3,off=0).
     * Reusing test A's own exact page table (L0 entry3 IS a real, valid
     * leaf) is the whole point of this isolation: if ptw_va_noncanonical
     * were missing or buggy, this walk would SUCCEED and the leaf code
     * would execute (x30 would become 1), exactly as in test A -- it
     * must instead fault, cause 12, before ever reaching the leaf.
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_j (.clk(clk), .rst(rst));
    logic halted_j = 1'b0;
    always @(posedge clk) if (dut_j.core0.trap_taken && dut_j.core0.is_ebreak) halted_j <= 1'b1;
    logic [63:0] mcause_j, mtval_j;
    logic        captured_j = 1'b0;
    always @(posedge clk) if (!captured_j && dut_j.core0.commit_now && dut_j.core0.pc == 64'h108) begin
        captured_j <= 1'b1;
        mcause_j   <= dut_j.core0.regfile0.gp_registers[20];
        mtval_j    <= dut_j.core0.regfile0.gp_registers[21];
    end

    /* ----------------------------------------------------------------
     * Test K: noncanonical VA, variant 2 -- the "all-clear-but-bit38"
     * pattern (bit38 itself set, bits[63:39] all 0 -- canonical would
     * require them all 1 to match bit38's own sign). vpn2 becomes 256
     * (bit38 is vpn2's own MSB), so this indexes an entirely different,
     * otherwise-still-real-and-valid 3-level mapping (same technique as
     * test J: a bug here would let the walk silently SUCCEED instead of
     * faulting).
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_k (.clk(clk), .rst(rst));
    logic halted_k = 1'b0;
    always @(posedge clk) if (dut_k.core0.trap_taken && dut_k.core0.is_ebreak) halted_k <= 1'b1;
    logic [63:0] mcause_k, mtval_k;
    logic        captured_k = 1'b0;
    always @(posedge clk) if (!captured_k && dut_k.core0.commit_now && dut_k.core0.pc == 64'h108) begin
        captured_k <= 1'b1;
        mcause_k   <= dut_k.core0.regfile0.gp_registers[20];
        mtval_k    <= dut_k.core0.regfile0.gp_registers[21];
    end
    logic [31:0] setup_e[0:29];
    logic [31:0] handler_e[0:7];
    logic [15:0] hw_e7[0:3];   // vpn0=7's own last dword: 3x c.nop + crossing_1 LOW16
    logic [15:0] hw_e8[0:3];   // vpn0=8's own first dword: crossing_1 HIGH16 + filler
    logic [15:0] hw_e3a[0:3];  // vpn0=3, dword0: 3x c.nop + crossing_2 LOW16
    logic [15:0] hw_e3b[0:3];  // vpn0=3, dword1: crossing_2 HIGH16 + ebreak + filler
    logic [31:0] crossing1, crossing2;
    int i; // shared packing-loop index, Test E only

    wire halted = halted_a && halted_b && halted_c && halted_d && halted_e
               && halted_f && halted_g && halted_h && halted_i && halted_j && halted_k;
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

        /*
         * ---- Test E setup ----
         * pmpaddr0 = 0x9000>>2 = 9216 (0x2400). HIGH=9216>>12=2,
         * LOW=9216-8192=1024 -- LOW fits ADDI's own +-2047 range
         * directly this time (unlike pmpaddr0/1/2 in dut3's own M6
         * test, which all needed a 3rd addi+or); still built via
         * addi+slli, not a bare addi, since 9216 itself exceeds 2047.
         */
        setup_e[0]  = enc_addi(5'd1,5'd0,8);
        setup_e[1]  = enc_slli(5'd1,5'd1,6'd60);
        setup_e[2]  = enc_addi(5'd2,5'd0,1);
        setup_e[3]  = enc_or(5'd1,5'd1,5'd2);
        setup_e[4]  = enc_csrrw(`CSR_SATP,5'd1);
        setup_e[5]  = enc_addi(5'd7,5'd0,2);
        setup_e[6]  = enc_slli(5'd7,5'd7,6'd12);
        setup_e[7]  = enc_addi(5'd21,5'd0,1024);
        setup_e[8]  = enc_or(5'd7,5'd7,5'd21);            // x7 = pmpaddr0 = 9216
        setup_e[9]  = enc_csrrw(`CSR_PMPADDR0,5'd7);
        setup_e[10] = enc_addi(5'd10,5'd0,13);             // region0 byte = TOR+R+X
        setup_e[11] = enc_csrrw(`CSR_PMPCFG0,5'd10);
        setup_e[12] = enc_addi(5'd3,5'd0,1);
        setup_e[13] = enc_slli(5'd3,5'd3,6'd11);           // mstatus.MPP = S
        setup_e[14] = enc_csrrw(`CSR_MSTATUS,5'd3);
        setup_e[15] = enc_addi(5'd4,5'd0,1028);
        setup_e[16] = enc_slli(5'd4,5'd4,6'd20);
        setup_e[17] = enc_addi(5'd5,5'd0,8);
        setup_e[18] = enc_slli(5'd5,5'd5,6'd12);
        setup_e[19] = enc_or(5'd4,5'd4,5'd5);               // x4 = VA vpn0=8 base = 0x40408000
        setup_e[20] = enc_addi(5'd4,5'd4,-8);                // x4 = VA vpn0=8 base - 8 = 0x40407FF8 (vpn0=7's own last dword)
        setup_e[21] = enc_csrrw(`CSR_MEPC,5'd4);
        setup_e[22] = enc_addi(5'd6,5'd0,256);
        setup_e[23] = enc_csrrw(`CSR_MTVEC,5'd6);
        setup_e[24] = `INSTR_HEX_MRET;
        setup_e[25] = NOP_INSN; // pad (word count must stay even)
        for (i = 0; i < 13; i = i + 1)
            dut_e.sram0.memory[i] = {setup_e[2*i+1], setup_e[2*i]};

        // Handler @0x100 (word 32): capture mcause/mtval, then rebuild
        // mepc to VA vpn0=3 base (instruction 2's own entry point,
        // comfortably inside region0) and mret back.
        dut_e.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        handler_e[0] = enc_addi(5'd26,5'd0,1028);
        handler_e[1] = enc_slli(5'd26,5'd26,6'd20);
        handler_e[2] = enc_addi(5'd27,5'd0,3);
        handler_e[3] = enc_slli(5'd27,5'd27,6'd12);
        handler_e[4] = enc_or(5'd26,5'd26,5'd27);            // x26 = VA vpn0=3 base = 0x40403000
        handler_e[5] = enc_csrrw(`CSR_MEPC,5'd26);
        handler_e[6] = `INSTR_HEX_MRET;
        handler_e[7] = NOP_INSN; // pad
        for (i = 0; i < 4; i = i + 1)
            dut_e.sram0.memory[33 + i] = {handler_e[2*i+1], handler_e[2*i]};

        /*
         * Program bytes, as 16-bit parcels -- built this way, not as
         * 64-bit words directly, to remove ANY ambiguity about where a
         * 2-byte compressed instruction or a split 4-byte instruction
         * half lands relative to an 8-byte dword boundary; the pack
         * loops below mirror core.sv's own hw0..hw3 =
         * instr_line_q[15:0]/[31:16]/[47:32]/[63:48] slicing exactly.
         * crossing_1's own HIGH16 lands at vpn0=8's own dword-truncated
         * base (offset 0 of that page), NOT at fetch_hi_vaddr's own
         * raw (pc+8) offset (0x006) -- the real bus read always fetches
         * whatever dword wb_addr_o's own [31:3] truncation selects, and
         * instr_hi_q always takes THAT dword's own low 16 bits
         * (wb_dat_i[15:0]), regardless of fetch_paddr_hi's own exact
         * non-dword-aligned value.
         */
        crossing1 = enc_addi(5'd13,5'd0,444);
        crossing2 = enc_addi(5'd14,5'd0,555);

        // vpn0=7 (PA 0x7000), last dword (PA 0x7FF8-0x7FFF, word 4095):
        // off 0xFF8-0xFFD: 3x c.nop. off 0xFFE-0xFFF: crossing_1 LOW16.
        hw_e7[0] = 16'h0001;
        hw_e7[1] = 16'h0001;
        hw_e7[2] = 16'h0001;
        hw_e7[3] = crossing1[15:0];
        dut_e.sram0.memory[4095] = {hw_e7[3], hw_e7[2], hw_e7[1], hw_e7[0]};

        // vpn0=8 (PA 0x9000), first dword (word 1152): crossing_1
        // HIGH16 (never actually fetched -- PMP denies before the real
        // bus read is ever issued) + 3x filler c.nop.
        hw_e8[0] = crossing1[31:16];
        hw_e8[1] = 16'h0001;
        hw_e8[2] = 16'h0001;
        hw_e8[3] = 16'h0001;
        dut_e.sram0.memory[1152] = {hw_e8[3], hw_e8[2], hw_e8[1], hw_e8[0]};

        // vpn0=3 (PA 0x4000), dword0 (word 2048): 3x c.nop + crossing_2
        // LOW16. dword1 (word 2049): crossing_2 HIGH16 + ebreak (does
        // not itself cross -- pc[2:1]!=2'b11 there) + 2-byte filler.
        hw_e3a[0] = 16'h0001;
        hw_e3a[1] = 16'h0001;
        hw_e3a[2] = 16'h0001;
        hw_e3a[3] = crossing2[15:0];
        dut_e.sram0.memory[2048] = {hw_e3a[3], hw_e3a[2], hw_e3a[1], hw_e3a[0]};
        hw_e3b[0] = crossing2[31:16];
        hw_e3b[1] = EBREAK_INSN[15:0];
        hw_e3b[2] = EBREAK_INSN[31:16];
        hw_e3b[3] = 16'h0001;
        dut_e.sram0.memory[2049] = {hw_e3b[3], hw_e3b[2], hw_e3b[1], hw_e3b[0]};

        dut_e.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801; // L2[1] -> L1@0x2000
        dut_e.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01; // L1[2] -> L0@0x3000
        dut_e.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0[3] -> leaf PPN=4  (PA 0x4000, vpn0=3, full RWX)
        dut_e.sram0.memory[1536 + 7] = 64'h0000_0000_0000_1CCF; // L0[7] -> leaf PPN=7  (PA 0x7000, vpn0=7, full RWX)
        dut_e.sram0.memory[1536 + 8] = 64'h0000_0000_0000_24CF; // L0[8] -> leaf PPN=9  (PA 0x9000, vpn0=8, full RWX -- PTE itself is VALID; PMP alone denies)

        /*
         * ---- Tests F/G/H: same shape as test C, but L0 entry3 is a
         * fully valid leaf (V=R=W=X=A=D=1, PPN=4) with one extra
         * malformed-arm bit set. ----
         */
        dut_f.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_f.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_f.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_f.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_f.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_f.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_f.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_f.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_f.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_f.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_f.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};
        dut_f.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_f.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_f.sram0.memory[1536 + 3] = 64'h6000_0000_0000_10CF; // PBMT[62:61]=2'b11 set alone

        dut_g.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_g.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_g.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_g.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_g.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_g.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_g.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_g.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_g.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_g.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_g.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};
        dut_g.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_g.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_g.sram0.memory[1536 + 3] = 64'h8000_0000_0000_10CF; // N[63]=1 set alone

        dut_h.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_h.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_h.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_h.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_h.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_h.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_h.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_h.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_h.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_h.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_h.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};
        dut_h.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_h.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_h.sram0.memory[1536 + 3] = 64'h1FC0_0000_0000_10CF; // reserved[60:54]=7'h7F set alone

        /*
         * ---- Test I: same shape, L0 entry3 = V=R=W=X=D=1, A=0. ----
         */
        dut_i.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_i.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_i.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_i.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_i.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_i.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_i.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_i.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_i.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_i.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_i.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};
        dut_i.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_i.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_i.sram0.memory[1536 + 3] = 64'h0000_0000_0000_108F; // V=R=W=X=D=1, A=0

        /*
         * ---- Test J: noncanonical VA variant 1 -- reuses test A's own
         * real 3-level table verbatim; only the M-mode setup differs
         * (an extra x7=1<<40 OR'd into x4 before csrrw mepc). ----
         */
        dut_j.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_j.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_j.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_j.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_j.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_j.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_j.sram0.memory[6] = {enc_addi(5'd7,5'd0,1), enc_or(5'd4,5'd4,5'd5)};
        dut_j.sram0.memory[7] = {enc_or(5'd4,5'd4,5'd7), enc_slli(5'd7,5'd7,6'd40)};
        dut_j.sram0.memory[8] = {enc_csrrw(`CSR_MEPC,5'd4), enc_addi(5'd6,5'd0,256)};
        dut_j.sram0.memory[9] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_j.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_j.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};
        dut_j.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801; // test A's own real L2 entry1 -> L1@0x2000
        dut_j.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01; // L1 entry2 -> L0@0x3000
        dut_j.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0 entry3 -> real valid leaf, PPN=4
        dut_j.sram0.memory[2048] = {EBREAK_INSN, enc_addi(5'd30,5'd0,1)}; // must NEVER be reached

        /*
         * ---- Test K: noncanonical VA variant 2 -- VA = 1<<38 exactly
         * (vpn2=256, vpn1=0, vpn0=0, off=0); own real, valid 3-level
         * table at the SAME indices, reachable only if the noncanonical
         * check is bypassed. ----
         */
        dut_k.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_k.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_k.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_k.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_k.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd38), enc_addi(5'd4,5'd0,1)};
        dut_k.sram0.memory[5] = {enc_csrrw(`CSR_MEPC,5'd4), enc_addi(5'd6,5'd0,256)};
        dut_k.sram0.memory[6] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_k.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_k.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};
        dut_k.sram0.memory[512 + 256] = 64'h0000_0000_0000_0801; // L2 entry256 (vpn2=1<<8) -> L1@0x2000
        dut_k.sram0.memory[1024 + 0] = 64'h0000_0000_0000_0C01;  // L1 entry0 -> L0@0x3000
        dut_k.sram0.memory[1536 + 0] = 64'h0000_0000_0000_10CF; // L0 entry0 -> real valid leaf, PPN=4
        dut_k.sram0.memory[2048] = {EBREAK_INSN, enc_addi(5'd30,5'd0,1)}; // must NEVER be reached

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

        check("E: crossing instr1 (denied HI half) never executed (x13==0)", dut_e.core0.regfile0.gp_registers[13], 64'd0);
        check("E: crossing instr1 produces mcause==1 (instruction access fault)", mcause_e, 64'd1);
        check("E: mtval == crossing instr1's own PC (vpn0=7 base + 0xFFE)", mtval_e, 64'h40407FFE);
        check({"E: crossing instr2 (permitted HI half, reached via mret after instr1's ",
            "trap) executed cleanly (x14==555) -- the direct regression proof: under the ",
            "bug this fixes, instr2 would ALSO have spuriously faulted, reusing instr1's ",
            "own stale, denied fetch_hi_paddr_q instead of resolving its own real address"},
            dut_e.core0.regfile0.gp_registers[14], 64'd555);

        check("F: PBMT bits[62:61] set alone -> malformed, mcause==12", mcause_f, 64'd12);
        check("F: mtval == the faulting VA", mtval_f, 64'h40403000);

        check("G: N bit[63] set alone -> malformed, mcause==12", mcause_g, 64'd12);
        check("G: mtval == the faulting VA", mtval_g, 64'h40403000);

        check("H: reserved bits[60:54] set alone -> malformed, mcause==12", mcause_h, 64'd12);
        check("H: mtval == the faulting VA", mtval_h, 64'h40403000);

        check("I: A=0 on a FETCH-stream leaf -> instruction page fault, mcause==12", mcause_i, 64'd12);
        check("I: mtval == the faulting VA", mtval_i, 64'h40403000);

        check("J: noncanonical VA (extra bit above bit38 set) faults, mcause==12", mcause_j, 64'd12);
        check("J: mtval == the full noncanonical VA actually used (not the truncated canonical form)",
              mtval_j, 64'h0000_0100_4040_3000);
        check("J: leaf code never executed (x30==0) -- proves the walk did NOT silently succeed despite reusing test A's own real, valid table",
              dut_j.core0.regfile0.gp_registers[30], 64'd0);

        check("K: noncanonical VA (bit38 set, upper bits clear) faults, mcause==12", mcause_k, 64'd12);
        check("K: mtval == the full noncanonical VA actually used", mtval_k, 64'h0000_0040_0000_0000);
        check("K: leaf code never executed (x30==0)", dut_k.core0.regfile0.gp_registers[30], 64'd0);

        $display("");
        $display("core_sv39_fetch_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_fetch_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
