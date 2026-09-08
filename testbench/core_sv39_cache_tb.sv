// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, Sv39 Milestone 6 (FINAL) -- end-to-end integration,
 * through the REAL cache-mediated path (core_cache_harness.sv -- real
 * icache0/dcache0 via cache_complex.sv, not the flat core_wb4_sram_harness
 * every earlier Sv39 milestone's own testbench used). Not new correctness
 * surface -- the proof that every prior milestone's mechanism composes
 * correctly together against a real, multi-cycle-refill memory system:
 * PTE reads are ordinary D$ accesses (decision 7 of the staged plan --
 * zero new cache plumbing), so a walk's own PTE reads are just as
 * subject to real cache miss/refill timing as any other load.
 *
 * Five DUTs, matching the staged plan's own Milestone 6 test list:
 *   dut1  -- all three leaf sizes (4KB/2MB/1GB) drive REAL fetch+load+
 *            store execution, not just isolated RTL-level walk checks.
 *   dut2a -- a load page fault, through the real cache path.
 *   dut2b -- a PMP-denied PTE read (fetch stream), through the real
 *            cache path -- literally reuses core_sv39_fetch_tb.sv's own
 *            proven test D page-table/PMP/code construction verbatim,
 *            just via core_cache_harness instead of core_wb4_sram_harness.
 *   dut3  -- the PMP-after-translation interaction: a PTE grants full
 *            RWX, but PMP denies the FINAL translated physical address
 *            -- must fault with PMP's own cause (5, not 13), proving
 *            decision 10's two-tier ordering survives real cache timing.
 *   dut4  -- the MPRV+MPP=U interaction: an M-mode access with MPRV=1,
 *            MPP=U against a U=0 page must be denied (cause 13) --
 *            something a PLAIN M-mode access would never trigger (M-mode
 *            ignores the U bit entirely), so this is a real proof
 *            mem_effective_priv resolved to U, not M, for the check.
 *   dut5  -- SFENCE.VMA genuinely invalidates a stale cached translation
 *            after a live PTE permission change: a store succeeds once
 *            (RW page), the SAME PTE is then rewritten (W cleared) via a
 *            direct physical-address write, SFENCE.VMA flushes the
 *            stale entry, and a retry of the identical store now
 *            correctly faults (cause 15) against the NEW permission.
 *
 * dut4/dut5 both stay entirely in M-mode (no mret at all), toggling
 * mstatus.MPRV/MPP directly -- this sidesteps needing a real M<->S
 * round trip (impossible without a trap) while still exercising a
 * genuinely translated, genuinely privilege-checked access via the
 * SAME mem_effective_priv signal a real S/U access would use.
 *
 * Longer programs use the flat-array-then-pack-into-memory[] idiom
 * core_fence_i_tb.sv already established (build a logic[31:0] prog[]
 * array via plain procedural assignment, then a small loop packs 2
 * instructions per 64-bit word) rather than manually hand-tracking
 * word indices -- a real, previously-paid-for lesson from this
 * project's own earlier hand-packed-word transcription bugs. Two
 * long-range (multi-megabyte) cross-region jumps in dut1 use a real
 * AUIPC+JALR pair (plain JAL's +-1MB range can't reach a differently-
 * mapped VPN1/VPN2 region, which is always at least 2MB/1GB away) --
 * the hi20/lo12 split is computed by the simulator itself via plain
 * SystemVerilog expressions (the same rounding technique
 * core_fence_i_tb.sv's own LUI+ADDI split already uses), not by hand,
 * for the identical reason.
 */
module core_sv39_cache_tb;

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
    function automatic logic [31:0] enc_csrrs_read(input logic [11:0] csr, input logic [4:0] rd);
        return encode_csr(csr, 5'd0, `FUNCT3_CSRRS, rd, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_csrrs_set(input logic [11:0] csr, input logic [4:0] rs1);
        return encode_csr(csr, rs1, `FUNCT3_CSRRS, 5'd0, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_csrrc_clear(input logic [11:0] csr, input logic [4:0] rs1);
        return encode_csr(csr, rs1, `FUNCT3_CSRRC, 5'd0, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_ld(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b011, rd, `OPC_LOAD);
    endfunction
    function automatic logic [31:0] enc_sd(input logic [4:0] rs2, rs1, input int imm);
        return encode_s(imm, rs2, rs1, 3'b011, `OPC_STORE);
    endfunction
    function automatic logic [31:0] enc_auipc(input logic [4:0] rd, input logic [19:0] imm20);
        return encode_u(imm20, rd, `OPC_AUIPC);
    endfunction
    function automatic logic [31:0] enc_jalr(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b000, rd, `OPC_JALR);
    endfunction
    localparam logic [31:0] EBREAK_INSN = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM};
    localparam logic [31:0] NOP_INSN    = 32'h00000013;
    // rs1=x0,rs2=x0,rd=x0 -- same derivation as core_sv39_tlb_tb.sv's own
    // SFENCE_VMA_INSN: funct7=0001001,funct3=000,opcode=1110011 ->
    // 32'h1200_0073, hand-verified against defaults/instructions_and_masks.sv's
    // own INSTR_SFENCE_VMA/INSTR_MASK_SFENCE_VMA.
    localparam logic [31:0] SFENCE_VMA_INSN = 32'h12000073;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    int i; // shared loop index for every prog[]-packing loop below

    /* ================================================================
     * dut1: all three leaf sizes drive real fetch+load+store execution
     * ================================================================
     * Shared page table (L2@0x1000/w512, L1@0x2000/w1024, L0@0x3000/w1536):
     *   L2[1] -> pointer to L1@PPN=2           (region A/B's own vpn2)
     *   L2[2] -> LEAF (gigapage, region C)      ppn2=ppn1=ppn0=0, RWXAD=1
     *   L1[2] -> pointer to L0@PPN=3            (region A's own vpn1)
     *   L1[6] -> LEAF (megapage, region B)      ppn2=ppn1=ppn0=0, RWXAD=1
     *   L0[3] -> LEAF PPN=4 (region A, 4KB)     PA=0x4000
     * VA_A=0x40403000(vpn2=1,vpn1=2,vpn0=3)->PA 0x4000 (4KB page)
     * VA_B=0x40C06000(vpn2=1,vpn1=6,vpn0=6)->PA 0x6000 (megapage, VA's
     *   own vpn0 passed through since the PTE's own ppn0/ppn1 are 0)
     * VA_C=0x80007000(vpn2=2,vpn1=0,vpn0=7)->PA 0x7000 (gigapage, same
     *   VA-passthrough reasoning, one level higher)
     */
    core_cache_harness dut1 (.clk(clk), .rst(rst));
    logic halted1 = 1'b0;
    always @(posedge clk) if (dut1.core0.trap_taken && dut1.core0.is_ebreak) halted1 <= 1'b1;

    localparam logic [63:0] VA_A = 64'h40403000;
    localparam logic [63:0] VA_B = 64'h40C06000;
    localparam logic [63:0] VA_C = 64'h80007000;

    logic [31:0] setup1[0:16];
    logic [31:0] regA[0:6];
    logic [31:0] regB[0:6];
    logic [31:0] regC[0:5];
    logic signed [63:0] diff_ab, diff_bc;
    logic [19:0] hi20_ab, hi20_bc;
    logic [11:0] lo12_ab, lo12_bc;

    /* ================================================================
     * dut2a: a load page fault (V=0 PTE), through the real cache path.
     * VA_CODE=0x40403000 (same shared shape as dut1's region A, PA
     * 0x4000 -- a fresh DUT, no collision); VA_DATA=0x40404000
     * (vpn0=4) -- L0[4] deliberately left unwritten (V=0).
     * ================================================================ */
    core_cache_harness dut2a (.clk(clk), .rst(rst));
    logic halted2a = 1'b0;
    always @(posedge clk) if (dut2a.core0.trap_taken && dut2a.core0.is_ebreak) halted2a <= 1'b1;
    logic [63:0] mcause_2a, mtval_2a;
    logic        captured_2a = 1'b0;
    always @(posedge clk) if (!captured_2a && dut2a.core0.commit_now && dut2a.core0.pc == 64'h108) begin
        captured_2a <= 1'b1;
        mcause_2a   <= dut2a.core0.regfile0.gp_registers[20];
        mtval_2a    <= dut2a.core0.regfile0.gp_registers[21];
    end
    logic [31:0] setup2a[0:16];
    logic [31:0] code2a[0:6];

    /* ================================================================
     * dut2b: a PMP-denied PTE read (fetch stream), through the real
     * cache path -- reuses core_sv39_fetch_tb.sv's own proven test D
     * construction verbatim (same VA/page-table/PMP-region shape),
     * just through core_cache_harness instead of the flat harness.
     * ================================================================ */
    core_cache_harness dut2b (.clk(clk), .rst(rst));
    logic halted2b = 1'b0;
    always @(posedge clk) if (dut2b.core0.trap_taken && dut2b.core0.is_ebreak) halted2b <= 1'b1;
    logic [63:0] mcause_2b, mtval_2b;
    logic        captured_2b = 1'b0;
    always @(posedge clk) if (!captured_2b && dut2b.core0.commit_now && dut2b.core0.pc == 64'h108) begin
        captured_2b <= 1'b1;
        mcause_2b   <= dut2b.core0.regfile0.gp_registers[20];
        mtval_2b    <= dut2b.core0.regfile0.gp_registers[21];
    end

    /* ================================================================
     * dut3: PMP-after-translation. VA_DATA=0x40403000 (vpn0=3, PA
     * 0x4000) has a fully-permissive PTE (RWX=1), but PMP denies
     * [0x4000,0x4008) outright. VA_CODE=0x40405000 (vpn0=5, PA 0x5000)
     * is PMP-permitted (R+X) and holds the actual code. Must fault
     * with cause 5 (load access fault), NOT 13 (page fault) -- the
     * direct proof a successful translation does not bypass the
     * existing, unmodified PMP enforcement on the final PA.
     *
     * The handler captures mcause/mtval (pc 0x100/0x104, unchanged),
     * but then -- unlike every other DUT's own "capture and immediately
     * ebreak" handler -- rewrites mepc to VA_PHASE2 (0x40407000, vpn0=7)
     * and mret's BACK into S-mode, where a completely independent second
     * load (VA2_DATA=0x40406000, vpn0=6, a real, PMP-PERMITTED page
     * holding a sentinel) must succeed. This is the direct, regression-
     * safety proof for a real RTL fix this milestone's own integration
     * testing found: mem_resolved_q, once set by the FIRST (denied)
     * load, was never cleared on a PMP-bail (only on a real S_MEM&&
     * wb_done completion, which a denied access never reaches) -- left
     * unfixed, this SECOND, unrelated load would have silently skipped
     * its own walk and reused the FIRST load's stale, denied PA instead
     * of the sentinel's real one. mcause_3/mtval_3's own capture trigger
     * stays at pc==0x108 (still one commit after the last csrrs, now the
     * mepc-rebuild sequence's own first instruction, not ebreak) -- see
     * that capture's own comment for why one commit of settling time
     * is required, not optional.
     * ================================================================ */
    core_cache_harness dut3 (.clk(clk), .rst(rst));
    logic halted3 = 1'b0;
    always @(posedge clk) if (dut3.core0.trap_taken && dut3.core0.is_ebreak) halted3 <= 1'b1;
    logic [63:0] mcause_3, mtval_3;
    logic        captured_3 = 1'b0;
    // pc==0x108, not 0x104 -- a real, self-caught same-cycle race in an
    // earlier draft: capturing AT the exact commit of the csrrs that
    // WRITES x21 reads the regfile's PRE-edge (stale, still-zero) value,
    // since the write itself only becomes visible after that same edge
    // settles. 0x108 (one commit later -- now the mepc-rebuild
    // sequence's own first instruction) gives x21 a full cycle to
    // settle, mirroring the original design's own capture-one-
    // instruction-after-the-last-write timing exactly.
    always @(posedge clk) if (!captured_3 && dut3.core0.commit_now && dut3.core0.pc == 64'h108) begin
        captured_3 <= 1'b1;
        mcause_3   <= dut3.core0.regfile0.gp_registers[20];
        mtval_3    <= dut3.core0.regfile0.gp_registers[21];
    end
    logic [31:0] setup3[0:35];
    logic [31:0] code3[0:6];
    logic [31:0] handler3[0:6];
    logic [31:0] phase2_3[0:6];

    /* ================================================================
     * dut4: MPRV+MPP=U. Stays in M-mode throughout (no mret) --
     * mstatus.MPP is 0 (U) at reset already, so only MPRV needs
     * setting. VA_X=0x40404000 (vpn0=4, PA 0x4000) maps a U=0 page
     * (R=1,W=1,X=0). A load through MPRV+MPP=U must fault (cause 13,
     * effective priv=U denied by U=0) -- something a PLAIN M-mode
     * access (which ignores U entirely) would never trigger.
     * ================================================================ */
    core_cache_harness dut4 (.clk(clk), .rst(rst));
    logic halted4 = 1'b0;
    always @(posedge clk) if (dut4.core0.trap_taken && dut4.core0.is_ebreak) halted4 <= 1'b1;
    logic [63:0] mcause_4, mtval_4;
    logic        captured_4 = 1'b0;
    always @(posedge clk) if (!captured_4 && dut4.core0.commit_now && dut4.core0.pc == 64'h108) begin
        captured_4 <= 1'b1;
        mcause_4   <= dut4.core0.regfile0.gp_registers[20];
        mtval_4    <= dut4.core0.regfile0.gp_registers[21];
    end
    logic [31:0] setup4[0:16];

    /* ================================================================
     * dut5: SFENCE.VMA invalidates a stale translation after a live
     * PTE permission change. VA_X=0x40403000 (vpn0=3, PA 0x4000),
     * initial PTE R=1,W=1,X=0. Entirely in M-mode: MPRV=1,MPP=S for
     * the translated store/load, MPRV=0 for a PLAIN (untranslated)
     * physical-address write that directly overwrites the PTE itself
     * (at PA 0x3018 = L0 table word 1539's own byte address) with
     * W=0. SFENCE.VMA flushes the stale (W=1) cached entry; the
     * identical store retried afterward must now fault (cause 15)
     * against the freshly-walked, now-read-only PTE.
     * ================================================================ */
    core_cache_harness dut5 (.clk(clk), .rst(rst));
    logic halted5 = 1'b0;
    always @(posedge clk) if (dut5.core0.trap_taken && dut5.core0.is_ebreak) halted5 <= 1'b1;
    logic [63:0] mcause_5, mtval_5;
    logic        captured_5 = 1'b0;
    always @(posedge clk) if (!captured_5 && dut5.core0.commit_now && dut5.core0.pc == 64'h108) begin
        captured_5 <= 1'b1;
        mcause_5   <= dut5.core0.regfile0.gp_registers[20];
        mtval_5    <= dut5.core0.regfile0.gp_registers[21];
    end
    logic [31:0] setup5[0:38];

    wire halted = halted1 && halted2a && halted2b && halted3 && halted4 && halted5;
    `include "halt_wait.sv"


    initial begin
        rst = 1;
        #1; // run after wb4_sram's own time-0 init


        /* ================= dut1 ================= */
        setup1[0]  = enc_addi(5'd1,5'd0,8);
        setup1[1]  = enc_slli(5'd1,5'd1,6'd60);
        setup1[2]  = enc_addi(5'd2,5'd0,1);
        setup1[3]  = enc_or(5'd1,5'd1,5'd2);
        setup1[4]  = enc_addi(5'd3,5'd0,1);
        setup1[5]  = enc_slli(5'd3,5'd3,6'd11);
        setup1[6]  = enc_csrrw(`CSR_SATP,5'd1);
        setup1[7]  = enc_csrrw(`CSR_MSTATUS,5'd3);
        setup1[8]  = enc_addi(5'd4,5'd0,1028);
        setup1[9]  = enc_slli(5'd4,5'd4,6'd20);
        setup1[10] = enc_addi(5'd5,5'd0,3);
        setup1[11] = enc_slli(5'd5,5'd5,6'd12);
        setup1[12] = enc_or(5'd4,5'd4,5'd5);
        setup1[13] = enc_csrrw(`CSR_MEPC,5'd4);
        setup1[14] = enc_addi(5'd6,5'd0,256);
        setup1[15] = enc_csrrw(`CSR_MTVEC,5'd6);
        setup1[16] = `INSTR_HEX_MRET;
        for (i = 0; i < 8; i = i + 1)
            dut1.sram0.memory[i] = {setup1[2*i+1], setup1[2*i]};
        dut1.sram0.memory[8][31:0] = setup1[16];
        dut1.sram0.memory[32] = {EBREAK_INSN, enc_addi(5'd31,5'd0,1)};

        // Region A @ VA_A (PA 0x4000, word 2048): fetch+store+load round trip.
        regA[0] = enc_addi(5'd10,5'd0,111);
        regA[1] = enc_auipc(5'd11,20'd0);
        regA[2] = enc_addi(5'd11,5'd11,'hFC);
        regA[3] = enc_sd(5'd10,5'd11,0);
        regA[4] = enc_ld(5'd12,5'd11,0);
        // regA[5]/[6]: long jump to VA_B -- computed below, after diff_ab exists.
        diff_ab   = $signed(VA_B) - $signed(VA_A + 64'h14);
        lo12_ab   = diff_ab[11:0];
        hi20_ab   = diff_ab[31:12] + (lo12_ab[11] ? 20'd1 : 20'd0);
        regA[5] = enc_auipc(5'd1, hi20_ab);
        regA[6] = enc_jalr(5'd0, 5'd1, int'($signed(lo12_ab)));
        for (i = 0; i < 3; i = i + 1)
            dut1.sram0.memory[2048 + i] = {regA[2*i+1], regA[2*i]};
        dut1.sram0.memory[2048 + 3][31:0] = regA[6];

        // Region B @ VA_B (PA 0x6000, word 3072): fetch+store+load round trip.
        regB[0] = enc_addi(5'd13,5'd0,222);
        regB[1] = enc_auipc(5'd14,20'd0);
        regB[2] = enc_addi(5'd14,5'd14,'hFC);
        regB[3] = enc_sd(5'd13,5'd14,0);
        regB[4] = enc_ld(5'd15,5'd14,0);
        diff_bc   = $signed(VA_C) - $signed(VA_B + 64'h14);
        lo12_bc   = diff_bc[11:0];
        hi20_bc   = diff_bc[31:12] + (lo12_bc[11] ? 20'd1 : 20'd0);
        regB[5] = enc_auipc(5'd1, hi20_bc);
        regB[6] = enc_jalr(5'd0, 5'd1, int'($signed(lo12_bc)));
        for (i = 0; i < 3; i = i + 1)
            dut1.sram0.memory[3072 + i] = {regB[2*i+1], regB[2*i]};
        dut1.sram0.memory[3072 + 3][31:0] = regB[6];

        // Region C @ VA_C (PA 0x7000, word 3584): fetch+store+load, then ebreak.
        regC[0] = enc_addi(5'd16,5'd0,333);
        regC[1] = enc_auipc(5'd17,20'd0);
        regC[2] = enc_addi(5'd17,5'd17,'hFC);
        regC[3] = enc_sd(5'd16,5'd17,0);
        regC[4] = enc_ld(5'd18,5'd17,0);
        regC[5] = EBREAK_INSN;
        // regC has 6 (EVEN) elements -- 3 full pairs, no leftover single
        // half like regA/regB's own 7-element (odd) packing needs. A
        // real, self-caught bug: an earlier draft reused regA/regB's
        // "2 pairs + 1 leftover" loop bound here unchanged, which never
        // wrote regC[4] (the LD) into memory at all and misplaced
        // regC[5] (EBREAK) into the word slot LD should have occupied.
        for (i = 0; i < 3; i = i + 1)
            dut1.sram0.memory[3584 + i] = {regC[2*i+1], regC[2*i]};

        dut1.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801; // L2[1] -> L1@0x2000
        dut1.sram0.memory[512 + 2]  = 64'h0000_0000_0000_00CF; // L2[2] -> LEAF gigapage (region C)
        dut1.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01; // L1[2] -> L0@0x3000
        dut1.sram0.memory[1024 + 6] = 64'h0000_0000_0000_00CF; // L1[6] -> LEAF megapage (region B)
        dut1.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0[3] -> LEAF PPN=4 (region A)


        /* ================= dut2a ================= */
        setup2a[0]  = enc_addi(5'd1,5'd0,8);
        setup2a[1]  = enc_slli(5'd1,5'd1,6'd60);
        setup2a[2]  = enc_addi(5'd2,5'd0,1);
        setup2a[3]  = enc_or(5'd1,5'd1,5'd2);
        setup2a[4]  = enc_addi(5'd3,5'd0,1);
        setup2a[5]  = enc_slli(5'd3,5'd3,6'd11);
        setup2a[6]  = enc_csrrw(`CSR_SATP,5'd1);
        setup2a[7]  = enc_csrrw(`CSR_MSTATUS,5'd3);
        setup2a[8]  = enc_addi(5'd4,5'd0,1028);
        setup2a[9]  = enc_slli(5'd4,5'd4,6'd20);
        setup2a[10] = enc_addi(5'd9,5'd0,3);
        setup2a[11] = enc_slli(5'd9,5'd9,6'd12);
        setup2a[12] = enc_or(5'd4,5'd4,5'd9);
        setup2a[13] = enc_csrrw(`CSR_MEPC,5'd4);
        setup2a[14] = enc_addi(5'd6,5'd0,256);
        setup2a[15] = enc_csrrw(`CSR_MTVEC,5'd6);
        setup2a[16] = `INSTR_HEX_MRET;
        for (i = 0; i < 8; i = i + 1)
            dut2a.sram0.memory[i] = {setup2a[2*i+1], setup2a[2*i]};
        dut2a.sram0.memory[8][31:0] = setup2a[16];
        dut2a.sram0.memory[32] = {enc_csrrs_read(`CSR_MTVAL,5'd21), enc_csrrs_read(`CSR_MCAUSE,5'd20)};
        dut2a.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        code2a[0] = enc_addi(5'd5,5'd0,1028);
        code2a[1] = enc_slli(5'd5,5'd5,6'd20);
        code2a[2] = enc_addi(5'd6,5'd0,4);
        code2a[3] = enc_slli(5'd6,5'd6,6'd12);
        code2a[4] = enc_or(5'd5,5'd5,5'd6);
        code2a[5] = enc_ld(5'd22,5'd5,0);
        code2a[6] = EBREAK_INSN;
        for (i = 0; i < 3; i = i + 1)
            dut2a.sram0.memory[2048 + i] = {code2a[2*i+1], code2a[2*i]};
        dut2a.sram0.memory[2048 + 3][31:0] = code2a[6];

        dut2a.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801;
        dut2a.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut2a.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0[3] -> CODE leaf
        // L0[4] deliberately left 0 (V=0) -- VA_DATA=0x40404000.


        /* ================= dut2b ================= */
        // Verbatim reuse of core_sv39_fetch_tb.sv's own proven test D.
        dut2b.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut2b.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut2b.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut2b.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut2b.sram0.memory[4] = {enc_csrrw(`CSR_PMPADDR0,5'd7), enc_addi(5'd7,5'd0,1026)};
        dut2b.sram0.memory[5] = {enc_csrrw(`CSR_PMPADDR1,5'd8), enc_addi(5'd8,5'd0,1028)};
        dut2b.sram0.memory[6] = {enc_slli(5'd9,5'd9,6'd12), enc_addi(5'd9,5'd0,2)};
        dut2b.sram0.memory[7] = {enc_addi(5'd10,5'd0,9), enc_csrrw(`CSR_PMPADDR2,5'd9)};   // 9 = TOR,R=1
        dut2b.sram0.memory[8] = {enc_slli(5'd11,5'd11,6'd8), enc_addi(5'd11,5'd0,8)};      // 8 = TOR,R=0
        dut2b.sram0.memory[9] = {enc_addi(5'd12,5'd0,9), enc_or(5'd10,5'd10,5'd11)};
        dut2b.sram0.memory[10] = {enc_or(5'd10,5'd10,5'd12), enc_slli(5'd12,5'd12,6'd16)};
        dut2b.sram0.memory[11] = {enc_addi(5'd4,5'd0,1028), enc_csrrw(`CSR_PMPCFG0,5'd10)};
        dut2b.sram0.memory[12] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut2b.sram0.memory[13] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut2b.sram0.memory[14] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut2b.sram0.memory[15] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut2b.sram0.memory[32] = {enc_csrrs_read(`CSR_MTVAL,5'd21), enc_csrrs_read(`CSR_MCAUSE,5'd20)};
        dut2b.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};
        dut2b.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801; // L2[1] -> L1@0x2000 (PMP-denied read)
        dut2b.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut2b.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // real leaf, never reached


        /* ================= dut3 ================= */
        setup3[0]  = enc_addi(5'd1,5'd0,8);
        setup3[1]  = enc_slli(5'd1,5'd1,6'd60);
        setup3[2]  = enc_addi(5'd2,5'd0,1);
        setup3[3]  = enc_or(5'd1,5'd1,5'd2);
        setup3[4]  = enc_csrrw(`CSR_SATP,5'd1);
        // pmpaddr0/1/2 (4096/4098/8192) all exceed ADDI's +-2047 12-bit
        // signed immediate range -- a real, self-caught test bug: a bare
        // enc_addi(...,4096) silently truncates to the low 12 bits (0),
        // matching exactly what a debug trace of this test's own first,
        // broken draft showed (pmpaddr0/2 both landing as 0). Built via
        // addi+slli (and a third addi+or for pmpaddr1's own non-zero low
        // byte) instead, the same technique already used throughout this
        // file for every other >2047 constant (VA_A/B/C, NEW_PTE, ...).
        setup3[5]  = enc_addi(5'd7,5'd0,1);
        setup3[6]  = enc_slli(5'd7,5'd7,6'd12);         // x7 = 4096 = pmpaddr0 (0x4000>>2)
        setup3[7]  = enc_csrrw(`CSR_PMPADDR0,5'd7);
        setup3[8]  = enc_addi(5'd8,5'd0,1);
        setup3[9]  = enc_slli(5'd8,5'd8,6'd12);
        setup3[10] = enc_addi(5'd17,5'd0,2);
        setup3[11] = enc_or(5'd8,5'd8,5'd17);           // x8 = 4098 = pmpaddr1 (0x4008>>2)
        setup3[12] = enc_csrrw(`CSR_PMPADDR1,5'd8);
        setup3[13] = enc_addi(5'd9,5'd0,2);
        setup3[14] = enc_slli(5'd9,5'd9,6'd12);          // x9 = 8192 = pmpaddr2 (0x8000>>2)
        setup3[15] = enc_csrrw(`CSR_PMPADDR2,5'd9);
        setup3[16] = enc_addi(5'd10,5'd0,9);          // region0 byte = TOR+R
        setup3[17] = enc_addi(5'd11,5'd0,8);          // region1 byte = TOR only (deny)
        setup3[18] = enc_slli(5'd11,5'd11,6'd8);
        setup3[19] = enc_or(5'd10,5'd10,5'd11);
        setup3[20] = enc_addi(5'd12,5'd0,13);         // region2 byte = TOR+R+X
        setup3[21] = enc_slli(5'd12,5'd12,6'd16);
        setup3[22] = enc_or(5'd10,5'd10,5'd12);
        setup3[23] = enc_csrrw(`CSR_PMPCFG0,5'd10);
        setup3[24] = enc_addi(5'd3,5'd0,1);
        setup3[25] = enc_slli(5'd3,5'd3,6'd11);
        setup3[26] = enc_csrrw(`CSR_MSTATUS,5'd3);
        setup3[27] = enc_addi(5'd4,5'd0,1028);
        setup3[28] = enc_slli(5'd4,5'd4,6'd20);
        setup3[29] = enc_addi(5'd5,5'd0,5);            // VA_CODE vpn0=5
        setup3[30] = enc_slli(5'd5,5'd5,6'd12);
        setup3[31] = enc_or(5'd4,5'd4,5'd5);
        setup3[32] = enc_csrrw(`CSR_MEPC,5'd4);
        setup3[33] = enc_addi(5'd6,5'd0,256);
        setup3[34] = enc_csrrw(`CSR_MTVEC,5'd6);
        setup3[35] = `INSTR_HEX_MRET;
        for (i = 0; i < 18; i = i + 1)
            dut3.sram0.memory[i] = {setup3[2*i+1], setup3[2*i]};
        dut3.sram0.memory[32] = {enc_csrrs_read(`CSR_MTVAL,5'd21), enc_csrrs_read(`CSR_MCAUSE,5'd20)};

        code3[0] = enc_addi(5'd7,5'd0,1028);
        code3[1] = enc_slli(5'd7,5'd7,6'd20);
        code3[2] = enc_addi(5'd8,5'd0,3);              // VA_DATA vpn0=3
        code3[3] = enc_slli(5'd8,5'd8,6'd12);
        code3[4] = enc_or(5'd7,5'd7,5'd8);
        code3[5] = enc_ld(5'd22,5'd7,0);
        code3[6] = EBREAK_INSN;
        for (i = 0; i < 3; i = i + 1)
            dut3.sram0.memory[2560 + i] = {code3[2*i+1], code3[2*i]}; // PA 0x5000 (VA_CODE)
        dut3.sram0.memory[2560 + 3][31:0] = code3[6];

        // Handler continuation @0x108 (word 33 onward): mepc <- VA_PHASE2
        // (0x40407000, vpn0=7), then mret back into S-mode -- see this
        // DUT's own header comment for why (mem_resolved_q regression proof).
        handler3[0] = enc_addi(5'd26,5'd0,1028);
        handler3[1] = enc_slli(5'd26,5'd26,6'd20);
        handler3[2] = enc_addi(5'd27,5'd0,7);           // VA_PHASE2 vpn0=7
        handler3[3] = enc_slli(5'd27,5'd27,6'd12);
        handler3[4] = enc_or(5'd26,5'd26,5'd27);
        handler3[5] = enc_csrrw(`CSR_MEPC,5'd26);
        handler3[6] = `INSTR_HEX_MRET;
        for (i = 0; i < 3; i = i + 1)
            dut3.sram0.memory[33 + i] = {handler3[2*i+1], handler3[2*i]};
        dut3.sram0.memory[33 + 3][31:0] = handler3[6];

        // Phase 2 @ VA_PHASE2 (PA 0x7000, word 3584 = 0x7000/8): a
        // completely independent second load, to a DIFFERENT VPN
        // (VA2_DATA = 0x40406000, vpn0=6, PMP-permitted) holding a known
        // sentinel -- must genuinely re-walk, not silently reuse the
        // FIRST (denied) load's own stale mem_resolved_q/
        // mem_resolved_paddr_q. A real, self-caught word-index bug in
        // an earlier draft used word 896 (=PA 0x1C00) here instead --
        // uninitialized memory decoded as an illegal instruction the
        // instant the (correctly-succeeding) walk tried to fetch it.
        phase2_3[0] = enc_addi(5'd23,5'd0,1028);
        phase2_3[1] = enc_slli(5'd23,5'd23,6'd20);
        phase2_3[2] = enc_addi(5'd24,5'd0,6);           // VA2_DATA vpn0=6
        phase2_3[3] = enc_slli(5'd24,5'd24,6'd12);
        phase2_3[4] = enc_or(5'd23,5'd23,5'd24);
        phase2_3[5] = enc_ld(5'd25,5'd23,0);
        phase2_3[6] = EBREAK_INSN;
        for (i = 0; i < 3; i = i + 1)
            dut3.sram0.memory[3584 + i] = {phase2_3[2*i+1], phase2_3[2*i]};
        dut3.sram0.memory[3584 + 3][31:0] = phase2_3[6];
        dut3.sram0.memory[3072] = 64'd777; // sentinel data @ PA 0x6000 (word 3072 = 0x6000/8), VA2_DATA

        dut3.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801;
        dut3.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut3.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0[3] -> leaf PPN=4 (VA_DATA, PA 0x4000, PMP-denied)
        dut3.sram0.memory[1536 + 5] = 64'h0000_0000_0000_14CF; // L0[5] -> leaf PPN=5 (VA_CODE, PA 0x5000, PMP-permitted)
        dut3.sram0.memory[1536 + 6] = 64'h0000_0000_0000_18C7; // L0[6] -> leaf PPN=6 (VA2_DATA, PA 0x6000, R+W, PMP-permitted)
        dut3.sram0.memory[1536 + 7] = 64'h0000_0000_0000_1CCB; // L0[7] -> leaf PPN=7 (VA_PHASE2, PA 0x7000, R+X, PMP-permitted)


        /* ================= dut4 ================= */
        setup4[0]  = enc_addi(5'd1,5'd0,8);
        setup4[1]  = enc_slli(5'd1,5'd1,6'd60);
        setup4[2]  = enc_addi(5'd2,5'd0,1);
        setup4[3]  = enc_or(5'd1,5'd1,5'd2);
        setup4[4]  = enc_csrrw(`CSR_SATP,5'd1);
        setup4[5]  = enc_addi(5'd3,5'd0,1);
        setup4[6]  = enc_slli(5'd3,5'd3,6'd17);        // x3 = MPRV bit; MPP stays 0=U from reset
        setup4[7]  = enc_csrrw(`CSR_MSTATUS,5'd3);
        setup4[8]  = enc_addi(5'd4,5'd0,1028);
        setup4[9]  = enc_slli(5'd4,5'd4,6'd20);
        setup4[10] = enc_addi(5'd5,5'd0,4);            // VA_X vpn0=4
        setup4[11] = enc_slli(5'd5,5'd5,6'd12);
        setup4[12] = enc_or(5'd4,5'd4,5'd5);
        setup4[13] = enc_addi(5'd6,5'd0,256);
        setup4[14] = enc_csrrw(`CSR_MTVEC,5'd6);
        setup4[15] = enc_ld(5'd22,5'd4,0);              // MUST fault -- cause 13
        setup4[16] = EBREAK_INSN;
        for (i = 0; i < 8; i = i + 1)
            dut4.sram0.memory[i] = {setup4[2*i+1], setup4[2*i]};
        dut4.sram0.memory[8][31:0] = setup4[16];
        dut4.sram0.memory[32] = {enc_csrrs_read(`CSR_MTVAL,5'd21), enc_csrrs_read(`CSR_MCAUSE,5'd20)};
        dut4.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        dut4.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801;
        dut4.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut4.sram0.memory[1536 + 4] = 64'h0000_0000_0000_10C7; // L0[4] -> PPN=4, R=1,W=1,X=0,U=0,A=D=1


        /* ================= dut5 ================= */
        setup5[0]  = enc_addi(5'd1,5'd0,8);
        setup5[1]  = enc_slli(5'd1,5'd1,6'd60);
        setup5[2]  = enc_addi(5'd2,5'd0,1);
        setup5[3]  = enc_or(5'd1,5'd1,5'd2);
        setup5[4]  = enc_csrrw(`CSR_SATP,5'd1);
        setup5[5]  = enc_addi(5'd3,5'd0,1);
        setup5[6]  = enc_slli(5'd3,5'd3,6'd17);        // x3 = MPRV bit
        setup5[7]  = enc_addi(5'd14,5'd0,1);
        setup5[8]  = enc_slli(5'd14,5'd14,6'd11);       // x14 = MPP=S bit
        setup5[9]  = enc_or(5'd3,5'd3,5'd14);
        setup5[10] = enc_csrrw(`CSR_MSTATUS,5'd3);      // mstatus <- MPRV=1,MPP=S
        setup5[11] = enc_addi(5'd4,5'd0,1028);
        setup5[12] = enc_slli(5'd4,5'd4,6'd20);
        setup5[13] = enc_addi(5'd15,5'd0,3);            // VA_X vpn0=3
        setup5[14] = enc_slli(5'd15,5'd15,6'd12);
        setup5[15] = enc_or(5'd4,5'd4,5'd15);            // x4 = VA_X = 0x40403000
        setup5[16] = enc_addi(5'd10,5'd0,111);
        setup5[17] = enc_sd(5'd10,5'd4,0);               // translated store, W=1 -- succeeds
        setup5[18] = enc_ld(5'd11,5'd4,0);               // translated load-back
        setup5[19] = enc_addi(5'd16,5'd0,1);
        setup5[20] = enc_slli(5'd16,5'd16,6'd17);
        setup5[21] = enc_csrrc_clear(`CSR_MSTATUS,5'd16); // clear MPRV
        setup5[22] = enc_addi(5'd12,5'd0,3);
        setup5[23] = enc_slli(5'd12,5'd12,6'd12);
        setup5[24] = enc_addi(5'd17,5'd0,24);
        setup5[25] = enc_or(5'd12,5'd12,5'd17);           // x12 = PA_PTE = 0x3018
        setup5[26] = enc_addi(5'd13,5'd0,1);
        setup5[27] = enc_slli(5'd13,5'd13,6'd12);
        setup5[28] = enc_addi(5'd19,5'd0,197);
        setup5[29] = enc_or(5'd13,5'd13,5'd19);           // x13 = NEW_PTE = 0x10C5 (W cleared)
        setup5[30] = enc_sd(5'd13,5'd12,0);               // plain M-mode physical write to the PTE
        setup5[31] = enc_addi(5'd16,5'd0,1);
        setup5[32] = enc_slli(5'd16,5'd16,6'd17);
        setup5[33] = enc_csrrs_set(`CSR_MSTATUS,5'd16);   // re-set MPRV; MPP still S
        setup5[34] = SFENCE_VMA_INSN;
        setup5[35] = enc_addi(5'd6,5'd0,256);
        setup5[36] = enc_csrrw(`CSR_MTVEC,5'd6);
        setup5[37] = enc_sd(5'd10,5'd4,0);                // retry store -- MUST fault now, cause 15
        setup5[38] = EBREAK_INSN;
        for (i = 0; i < 19; i = i + 1)
            dut5.sram0.memory[i] = {setup5[2*i+1], setup5[2*i]};
        dut5.sram0.memory[19][31:0] = setup5[38];
        dut5.sram0.memory[32] = {enc_csrrs_read(`CSR_MTVAL,5'd21), enc_csrrs_read(`CSR_MCAUSE,5'd20)};
        dut5.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        dut5.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801;
        dut5.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut5.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10C7; // L0[3] -> PPN=4, R=1,W=1,X=0,U=0,A=D=1


        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "Sv39 cache-mediated integration test never halted");

        // ---- dut1: three leaf sizes ----
        check("dut1: region A (4KB) fetch marker (x10==111)", dut1.core0.regfile0.gp_registers[10], 64'd111);
        check("dut1: region A (4KB) store+load round trip (x12==111)", dut1.core0.regfile0.gp_registers[12], 64'd111);
        check("dut1: region B (megapage) fetch marker (x13==222)", dut1.core0.regfile0.gp_registers[13], 64'd222);
        check("dut1: region B (megapage) store+load round trip (x15==222)", dut1.core0.regfile0.gp_registers[15], 64'd222);
        check("dut1: region C (gigapage) fetch marker (x16==333)", dut1.core0.regfile0.gp_registers[16], 64'd333);
        check("dut1: region C (gigapage) store+load round trip (x18==333)", dut1.core0.regfile0.gp_registers[18], 64'd333);

        // ---- dut2a: load page fault through the cache ----
        check("dut2a: mcause==13 (load page fault)", mcause_2a, 64'd13);
        check("dut2a: mtval == the faulting virtual address", mtval_2a, 64'h40404000);
        check("dut2a: dest register unchanged (no writeback)", dut2a.core0.regfile0.gp_registers[22], 64'd0);

        // ---- dut2b: PMP-denied PTE read (fetch) through the cache ----
        check("dut2b: mcause==1 (access fault), NOT 12", mcause_2b, 64'd1);
        check("dut2b: mtval == the faulting instruction's own VA", mtval_2b, 64'h40403000);

        // ---- dut3: PMP-after-translation ----
        check("dut3: mcause==5 (load access fault), NOT 13", mcause_3, 64'd5);
        check("dut3: mtval == the faulting VIRTUAL address (not the PA)", mtval_3, 64'h40403000);
        check("dut3: dest register unchanged (no writeback)", dut3.core0.regfile0.gp_registers[22], 64'd0);
        check("dut3: a SECOND, unrelated translated load (post-mret) genuinely re-walks (x25==777), not stale reuse of the first load's own denied PA", dut3.core0.regfile0.gp_registers[25], 64'd777);

        // ---- dut4: MPRV+MPP=U ----
        check("dut4: mcause==13 (U-mode denied by U=0 page)", mcause_4, 64'd13);
        check("dut4: mtval == VA_X", mtval_4, 64'h40404000);
        check("dut4: dest register unchanged (no writeback)", dut4.core0.regfile0.gp_registers[22], 64'd0);

        // ---- dut5: SFENCE.VMA after a live PTE permission change ----
        check("dut5: first (RW-permitted) store's marker set (x10==111)", dut5.core0.regfile0.gp_registers[10], 64'd111);
        check("dut5: first store's own load-back succeeded (x11==111)", dut5.core0.regfile0.gp_registers[11], 64'd111);
        check("dut5: retry store faults (cause 15) against the NEW, re-walked permission", mcause_5, 64'd15);
        check("dut5: mtval == VA_X (the retry store's own faulting VA)", mtval_5, 64'h40403000);

        $display("");
        $display("core_sv39_cache_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_cache_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
