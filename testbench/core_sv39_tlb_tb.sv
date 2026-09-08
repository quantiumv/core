// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, Sv39 Milestone 5 -- the 4-entry TLB + real SFENCE.VMA
 * flush, via core_wb4_sram_harness (flat memory, no cache -- same
 * "isolate then integrate" staging as Milestones 3/4's own testbenches;
 * the real cache-mediated path is Milestone 6's own closing integration
 * test).
 *
 * Every one of core.sv's three translated-access streams (S_FETCH,
 * S_FETCH_HI, S_MEM) re-issues its OWN translation lookup on every single
 * fetch/access, even a second instruction decoded from the SAME
 * already-fetched dword -- there is no "same dword as last time" cache at
 * the FSM level below the TLB itself. This means two INSTRUCTIONS packed
 * into one 64-bit dword (the low half at pc, the high half at pc+4) are
 * two INDEPENDENT translation lookups to the same VPN -- exactly the
 * mechanism these tests exploit to get a walk-then-hit pair cheaply,
 * without needing a second dword at all.
 *
 * White-box "did a real walk happen" observation reuses core_pmp_tb.sv's
 * own precedent of a small hand-written counter (not
 * state_reached_monitor.sv's sticky flag, which can only ever answer
 * "ever", not "how many times") -- ptw_entry_count_X below counts
 * TRANSITIONS into S_PTW (a full 3-level walk stays in S_PTW
 * continuously across levels, per the state-transition FSM's own
 * self-loop shape, so this correctly counts "number of separate walks",
 * not "number of PTW cycles").
 *
 * Five tests, matching the staged plan's own test list for this
 * milestone exactly:
 *   A. a hit correctly skips the walk (2 instructions packed into one
 *      leaf dword: the first fetch walks and fills the TLB, the SECOND
 *      -- a completely independent translation lookup to the SAME VPN --
 *      must hit, never revisiting S_PTW).
 *   B. a miss on a genuinely different VPN still walks, even
 *      immediately after an unrelated VPN was just cached.
 *   C. round-robin eviction order is deterministic: fill all 4 entries
 *      (4 distinct VPNs), force a 5th, distinct VPN in (evicting the
 *      oldest slot), then prove the evicted VPN genuinely re-walks while
 *      an untouched VPN still hits.
 *   D. SFENCE.VMA genuinely invalidates a cached entry -- a repeat
 *      access to the SAME VPN, with an intervening SFENCE.VMA, must
 *      re-walk (contrast with test A, where the identical repeat access
 *      WITHOUT an intervening SFENCE.VMA correctly hits).
 *   E. superpage partial-tag matching: a megapage (level-1 leaf) entry
 *      hits across its whole VPN[0] range -- two addresses sharing the
 *      same vpn2:vpn1 but DIFFERENT vpn0 both resolve through the SAME
 *      cached entry, with the VA's own (not the PTE's) vpn0 correctly
 *      passed through for each.
 *
 * PTE bit layout used throughout (spec-fixed, same as Milestones 3/4's
 * own testbenches): V[0] R[1] W[2] X[3] U[4] G[5] A[6] D[7] RSW[9:8]
 * PPN0[18:10] PPN1[27:19] PPN2[53:28].
 */
module core_sv39_tlb_tb;

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
    function automatic logic [31:0] enc_jal(input logic [4:0] rd, input int imm);
        return encode_j(imm, rd, `OPC_JAL);
    endfunction
    localparam logic [31:0] EBREAK_INSN = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM};
    localparam logic [31:0] NOP_INSN    = 32'h00000013;
    // rs1=x0,rs2=x0,rd=x0 (rs1/rs2 ignored per decision 3 of the staged
    // plan regardless of their value) -- funct7=0001001,funct3=000,
    // opcode=1110011 per defaults/instructions_and_masks.sv's own
    // INSTR_SFENCE_VMA/INSTR_MASK_SFENCE_VMA, hand-verified: binary
    // 0001001_00000_00000_000_00000_1110011 = 32'h1200_0073.
    localparam logic [31:0] SFENCE_VMA_INSN = 32'h12000073;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    // Shared M-mode setup shape, reused (with different VA-building
    // immediates) by every test below: satp<-Sv39/PPN=1 (L2@0x1000),
    // mstatus.MPP<-S, mepc<-the test's own entry VA, mtvec<-0x100 (a
    // defensive fallback -- halts immediately if anything traps
    // unexpectedly, so a real bug shows up as a wrong marker/count
    // instead of a silent hang), mret.
    //   word0: slli x1,x1,60 ; addi x1,x0,8        (x1 = satp MODE field)
    //   word1: or   x1,x1,x2 ; addi x2,x0,1         (x2 = L2 PPN=1)
    //   word2: addi x3,x0,1  ; csrrw satp,x1
    //   word3: csrrw mstatus,x3 ; slli x3,x3,11     (mstatus.MPP = S)
    //   word4: slli x4,x4,20 ; addi x4,x0,HIGH_IMM  (x4 = VA[31:20]<<20)
    //   word5: slli x5,x5,12 ; addi x5,x0,LOW_IMM   (x5 = VA[19:12]<<12)
    //   word6: csrrw mepc,x4 ; or   x4,x4,x5         (x4 = entry VA)
    //   word7: csrrw mtvec,x6 ; addi x6,x0,0x100
    //   word8: mret ; nop (pad)
    //   word32: fallback handler -- ebreak ; addi x31,x0,1

    /* ----------------------------------------------------------------
     * Test A: a hit correctly skips the walk.
     * VA = 0x40403000 (vpn2=1,vpn1=2,vpn0=3) -- same page-table shape
     * Milestone 3's own core_sv39_fetch_tb.sv test A used (a fresh DUT,
     * so no collision). Leaf dword @0x4000 packs 2 instructions: the
     * LOW half (pc=0x4000) is the FIRST-ever access to this VPN --
     * must walk. The HIGH half (pc=0x4004) is a completely independent
     * translation lookup to the SAME VPN -- must hit.
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_a (.clk(clk), .rst(rst));
    logic halted_a = 1'b0;
    always @(posedge clk) if (dut_a.core0.trap_taken && dut_a.core0.is_ebreak) halted_a <= 1'b1;
    logic ptw_prev_a = 1'b0;
    int ptw_count_a = 0;
    always @(negedge clk) begin
        if ((dut_a.core0.state == dut_a.core0.S_PTW) && !ptw_prev_a) ptw_count_a <= ptw_count_a + 1;
        ptw_prev_a <= (dut_a.core0.state == dut_a.core0.S_PTW);
    end

    /* ----------------------------------------------------------------
     * Test B: a miss on a different VPN still walks, right after an
     * unrelated VPN was just cached. VA1 = 0x40403000 (vpn0=3, as test
     * A); VA2 = 0x40405000 (vpn0=5) -- same L2/L1, a second L0 entry.
     * Page1's own dword: low=addi marker (walk), high=JAL to VA2 (hit,
     * same VPN as VA1). Page2's own dword: low=addi marker (MUST walk
     * -- different VPN), high=ebreak (hit, same VPN as VA2).
     * ptw_count is snapshotted right as the JAL retires (pc==VA1+4,
     * BEFORE VA2's own walk can have started) to prove page1 alone
     * only ever cost one walk, then checked again at final halt.
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_b (.clk(clk), .rst(rst));
    logic halted_b = 1'b0;
    always @(posedge clk) if (dut_b.core0.trap_taken && dut_b.core0.is_ebreak) halted_b <= 1'b1;
    logic ptw_prev_b = 1'b0;
    int ptw_count_b = 0;
    always @(negedge clk) begin
        if ((dut_b.core0.state == dut_b.core0.S_PTW) && !ptw_prev_b) ptw_count_b <= ptw_count_b + 1;
        ptw_prev_b <= (dut_b.core0.state == dut_b.core0.S_PTW);
    end
    int ptw_count_b_mid;
    logic captured_b_mid = 1'b0;
    always @(posedge clk) if (!captured_b_mid && dut_b.core0.commit_now && dut_b.core0.pc == 64'h40403004) begin
        captured_b_mid <= 1'b1;
        ptw_count_b_mid <= ptw_count_b;
    end

    /* ----------------------------------------------------------------
     * Test C: round-robin eviction order is deterministic. 5 distinct
     * 4KB pages under one shared L0 table (vpn2=1,vpn1=7,vpn0=0..4),
     * VA0=0x40E00000 .. VA4=0x40E04000. Visited in order via a JAL
     * chain: VA0->VA1->VA2->VA3->VA4 fills all 4 entries (0,1,2,3) then
     * evicts entry0 (VA0's own slot, tlb_replace_q wraps 3->0) to cache
     * VA4. VA4's own JAL then revisits VA0 at a DIFFERENT offset
     * (VA0+8, same VPN, avoiding VA0's own dword which would just loop
     * the chain again) -- this MUST miss (entry0 no longer holds VA0)
     * and re-walks, itself evicting entry1 (VA1's own slot). Finally
     * jumps to VA2+8 (same VPN as VA2, a DIFFERENT offset avoiding
     * VA2's own chain dword) -- entry2 was never touched by any
     * eviction, so this MUST hit. Needs a larger flat memory (leaf PPNs
     * 10-14, PA 0xA000-0xE000) than the 4096-word/32KB default.
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(8192)) dut_c (.clk(clk), .rst(rst));
    logic halted_c = 1'b0;
    always @(posedge clk) if (dut_c.core0.trap_taken && dut_c.core0.is_ebreak) halted_c <= 1'b1;
    logic ptw_prev_c = 1'b0;
    int ptw_count_c = 0;
    always @(negedge clk) begin
        if ((dut_c.core0.state == dut_c.core0.S_PTW) && !ptw_prev_c) ptw_count_c <= ptw_count_c + 1;
        ptw_prev_c <= (dut_c.core0.state == dut_c.core0.S_PTW);
    end

    /* ----------------------------------------------------------------
     * Test D: SFENCE.VMA genuinely invalidates a cached entry. VA =
     * 0x40404000 (vpn2=1,vpn1=2,vpn0=4). Leaf spans 2 dwords: dword0
     * low=addi x30 (walk#1, fills TLB), high=SFENCE.VMA (pc=VA+4, its
     * OWN fetch is a HIT -- same VPN as the walk that just filled it --
     * but its EXECUTION flushes all 4 entries). dword1 low=addi x29
     * (pc=VA+8, a NEW S_FETCH to the SAME VPN -- must walk AGAIN, since
     * the entry was just flushed -- contrast with test A, where the
     * identical repeat access WITHOUT an intervening SFENCE.VMA hits),
     * high=ebreak (pc=VA+0xC, hits -- same VPN, freshly refilled by
     * walk#2).
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_d (.clk(clk), .rst(rst));
    logic halted_d = 1'b0;
    always @(posedge clk) if (dut_d.core0.trap_taken && dut_d.core0.is_ebreak) halted_d <= 1'b1;
    logic ptw_prev_d = 1'b0;
    int ptw_count_d = 0;
    always @(negedge clk) begin
        if ((dut_d.core0.state == dut_d.core0.S_PTW) && !ptw_prev_d) ptw_count_d <= ptw_count_d + 1;
        ptw_prev_d <= (dut_d.core0.state == dut_d.core0.S_PTW);
    end

    /* ----------------------------------------------------------------
     * Test E: superpage partial-tag matching. L1@0x2000 entry[vpn1=6]
     * IS the leaf (a megapage -- level-1 leaf, PPN1/PPN2 real, PPN0
     * must be 0). PPN2=PPN1=0 chosen deliberately so the resolved PA
     * stays tiny (== the accessing VA's own vpn0, in pages) --
     * PA_X=0x5000 (vpn0=5), PA_Y=0x6000 (vpn0=6). VA_X=0x40C05000,
     * VA_Y=0x40C06000 -- same vpn2:vpn1 (same megapage), DIFFERENT
     * vpn0. VA_X's own fetch walks (finds the leaf AT level 1); the
     * JAL to VA_Y -- a DIFFERENT vpn0 within the SAME cached megapage
     * -- must still hit via the level-aware partial-tag match (only
     * vpn2:vpn1 are compared for a level-1 entry), with the VA's own
     * (not the PTE's, which is 0) vpn0 correctly reconstructed into
     * VA_Y's own distinct PA.
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_e (.clk(clk), .rst(rst));
    logic halted_e = 1'b0;
    always @(posedge clk) if (dut_e.core0.trap_taken && dut_e.core0.is_ebreak) halted_e <= 1'b1;
    logic ptw_prev_e = 1'b0;
    int ptw_count_e = 0;
    always @(negedge clk) begin
        if ((dut_e.core0.state == dut_e.core0.S_PTW) && !ptw_prev_e) ptw_count_e <= ptw_count_e + 1;
        ptw_prev_e <= (dut_e.core0.state == dut_e.core0.S_PTW);
    end

    /* ----------------------------------------------------------------
     * Test F: SFENCE.VMA that TRAPS must NOT flush the TLB -- the
     * regression proof for a real bug found post-M6 by an independent
     * adversarial re-review: the flush write (core.sv, near
     * "commit_now && is_sfence_vma") was unconditional, omitting the
     * !instr_faulted guard every OTHER commit-time side effect in that
     * file (csr_we, reg_write) already applies -- so an S-mode
     * SFENCE.VMA that traps as illegal (mstatus.TVM=1) still wiped the
     * whole TLB even though the instruction architecturally never
     * executed. VA_X=0x40403000 (vpn0=3, PA 0x4000): the leaf dword's
     * own fetch (walk#1) fills the TLB; SFENCE.VMA's OWN fetch (same
     * VPN) hits, but its EXECUTION traps (TVM=1, S-mode) instead of
     * ever flushing. The handler captures mcause, then mret's to
     * VA_X+0x100 -- a DIFFERENT offset within the SAME 4KB page (same
     * VPN) -- which must still HIT (ptw_count stays at 1) if the fix
     * is correct; under the bug, the spurious flush would force a
     * SECOND walk there (ptw_count becomes 2).
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_f (.clk(clk), .rst(rst));
    logic halted_f = 1'b0;
    always @(posedge clk) if (dut_f.core0.trap_taken && dut_f.core0.is_ebreak) halted_f <= 1'b1;
    logic ptw_prev_f = 1'b0;
    int ptw_count_f = 0;
    always @(negedge clk) begin
        if ((dut_f.core0.state == dut_f.core0.S_PTW) && !ptw_prev_f) ptw_count_f <= ptw_count_f + 1;
        ptw_prev_f <= (dut_f.core0.state == dut_f.core0.S_PTW);
    end
    logic [63:0] mcause_f;
    logic        captured_f = 1'b0;
    always @(posedge clk) if (!captured_f && dut_f.core0.commit_now && dut_f.core0.pc == 64'h104) begin
        captured_f <= 1'b1;
        mcause_f   <= dut_f.core0.regfile0.gp_registers[20];
    end
    logic [31:0] handler_f[0:8];
    int j; // shared packing-loop index, Test F only

    wire halted = halted_a && halted_b && halted_c && halted_d && halted_e && halted_f;
    `include "halt_wait.sv"


    initial begin
        rst = 1;
        #1; // run after wb4_sram's own time-0 init

        /* ================= Test A ================= */
        dut_a.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_a.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_a.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_a.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_a.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)}; // VA>>20 = 0x404
        dut_a.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};    // vpn0=3
        dut_a.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_a.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_a.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_a.sram0.memory[32] = {EBREAK_INSN, enc_addi(5'd31,5'd0,1)};
        dut_a.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801; // L2[1] -> L1@0x2000
        dut_a.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01; // L1[2] -> L0@0x3000
        dut_a.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0[3] -> leaf PPN=4 (PA 0x4000)
        // Leaf @0x4000 (word 2048): low=addi x30,x0,1 (walk), high=ebreak (hit).
        dut_a.sram0.memory[2048] = {EBREAK_INSN, enc_addi(5'd30,5'd0,1)};

        /* ================= Test B ================= */
        dut_b.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_b.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_b.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_b.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_b.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_b.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_b.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_b.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_b.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_b.sram0.memory[32] = {EBREAK_INSN, enc_addi(5'd31,5'd0,1)};
        dut_b.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801;
        dut_b.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_b.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0[3] -> leaf PPN=4 (VA1, PA 0x4000)
        dut_b.sram0.memory[1536 + 5] = 64'h0000_0000_0000_14CF; // L0[5] -> leaf PPN=5 (VA2, PA 0x5000)
        // Page1 @0x4000 (word 2048): low=addi x20,x0,1 (walk), high=JAL VA2 (hit).
        // JAL at VA1+4=0x40403004 -> VA2=0x40405000: imm = 0x1FFC = 8188.
        dut_b.sram0.memory[2048] = {enc_jal(5'd0, 8188), enc_addi(5'd20,5'd0,1)};
        // Page2 @0x5000 (word 2560): low=addi x21,x0,1 (MUST walk -- different VPN), high=ebreak (hit).
        dut_b.sram0.memory[2560] = {EBREAK_INSN, enc_addi(5'd21,5'd0,1)};

        /* ================= Test C ================= */
        dut_c.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_c.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_c.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_c.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_c.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1038)}; // VA0>>20 = 0x40E
        dut_c.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,0)};    // vpn0=0
        dut_c.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_c.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_c.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_c.sram0.memory[32] = {EBREAK_INSN, enc_addi(5'd31,5'd0,1)};
        dut_c.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801; // L2[1] -> L1@0x2000
        dut_c.sram0.memory[1024 + 7] = 64'h0000_0000_0000_0C01; // L1[7] (vpn1=7) -> L0@0x3000
        dut_c.sram0.memory[1536 + 0] = 64'h0000_0000_0000_28CF; // L0[0] -> leaf PPN=10 (PA 0xA000)
        dut_c.sram0.memory[1536 + 1] = 64'h0000_0000_0000_2CCF; // L0[1] -> leaf PPN=11 (PA 0xB000)
        dut_c.sram0.memory[1536 + 2] = 64'h0000_0000_0000_30CF; // L0[2] -> leaf PPN=12 (PA 0xC000)
        dut_c.sram0.memory[1536 + 3] = 64'h0000_0000_0000_34CF; // L0[3] -> leaf PPN=13 (PA 0xD000)
        dut_c.sram0.memory[1536 + 4] = 64'h0000_0000_0000_38CF; // L0[4] -> leaf PPN=14 (PA 0xE000)
        // Page0 @0xA000 (word 5120): low=addi x20 (walk#1, fills entry0),
        // high=JAL VA1 (hit). JAL at VA0+4=0x40E00004 -> VA1=0x40E01000: imm=0xFFC=4092.
        dut_c.sram0.memory[5120] = {enc_jal(5'd0, 4092), enc_addi(5'd20,5'd0,1)};
        // Page0, second dword @0xA008 (word 5121): low=addi x25 (revisit
        // VA0 -- entry0 was evicted by page4 below, so this MUST walk
        // again, filling entry1 and evicting VA1's own slot), high=JAL
        // VA2+8. JAL at VA0b+4=0x40E0000C -> VA2b=0x40E02008: imm=0x1FFC=8188.
        dut_c.sram0.memory[5121] = {enc_jal(5'd0, 8188), enc_addi(5'd25,5'd0,1)};
        // Page1 @0xB000 (word 5632): low=addi x21 (walk#2, fills entry1),
        // high=JAL VA2. JAL at VA1+4=0x40E01004 -> VA2=0x40E02000: imm=0xFFC=4092.
        dut_c.sram0.memory[5632] = {enc_jal(5'd0, 4092), enc_addi(5'd21,5'd0,1)};
        // Page2 @0xC000 (word 6144): low=addi x22 (walk#3, fills entry2),
        // high=JAL VA3. JAL at VA2+4=0x40E02004 -> VA3=0x40E03000: imm=0xFFC=4092.
        dut_c.sram0.memory[6144] = {enc_jal(5'd0, 4092), enc_addi(5'd22,5'd0,1)};
        // Page2, second dword @0xC008 (word 6145): low=addi x26 (revisit
        // VA2 -- entry2 was NEVER evicted, so this MUST hit), high=ebreak.
        dut_c.sram0.memory[6145] = {EBREAK_INSN, enc_addi(5'd26,5'd0,1)};
        // Page3 @0xD000 (word 6656): low=addi x23 (walk#4, fills entry3),
        // high=JAL VA4. JAL at VA3+4=0x40E03004 -> VA4=0x40E04000: imm=0xFFC=4092.
        dut_c.sram0.memory[6656] = {enc_jal(5'd0, 4092), enc_addi(5'd23,5'd0,1)};
        // Page4 @0xE000 (word 7168): low=addi x24 (walk#5, fills entry0,
        // EVICTING VA0's own slot -- tlb_replace_q wraps 3->0->1),
        // high=JAL VA0+8. JAL at VA4+4=0x40E04004 -> VA0b=0x40E00008:
        // imm = 0x40E00008-0x40E04004 = -0x3FFC = -16380.
        dut_c.sram0.memory[7168] = {enc_jal(5'd0, -16380), enc_addi(5'd24,5'd0,1)};

        /* ================= Test D ================= */
        dut_d.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_d.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_d.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_d.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_d.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_d.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,4)}; // vpn0=4
        dut_d.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_d.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_d.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_d.sram0.memory[32] = {EBREAK_INSN, enc_addi(5'd31,5'd0,1)};
        dut_d.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801;
        dut_d.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_d.sram0.memory[1536 + 4] = 64'h0000_0000_0000_10CF; // L0[4] -> leaf PPN=4 (PA 0x4000)
        // Leaf @0x4000 (word 2048): low=addi x30 (walk#1), high=SFENCE.VMA
        // (hit for its OWN fetch; execution flushes the whole TLB).
        dut_d.sram0.memory[2048] = {SFENCE_VMA_INSN, enc_addi(5'd30,5'd0,1)};
        // @0x4008 (word 2049): low=addi x29 (MUST walk again -- flushed),
        // high=ebreak (hit -- refilled by walk#2).
        dut_d.sram0.memory[2049] = {EBREAK_INSN, enc_addi(5'd29,5'd0,2)};

        /* ================= Test E ================= */
        dut_e.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_e.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_e.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_e.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_e.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1036)}; // VA_X>>20 = 0x40C
        dut_e.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,5)};    // vpn0=5
        dut_e.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_e.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_e.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_e.sram0.memory[32] = {EBREAK_INSN, enc_addi(5'd31,5'd0,1)};
        dut_e.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801; // L2[1] -> L1@0x2000
        dut_e.sram0.memory[1024 + 6] = 64'h0000_0000_0000_00CF; // L1[6] (vpn1=6) -> LEAF megapage, ppn2=ppn1=ppn0=0
        // Page_X @0x5000 (word 2560): low=addi x30 (walk -- finds the
        // leaf AT LEVEL 1), high=JAL VA_Y (hit, different vpn0, SAME
        // cached megapage entry). JAL at VA_X+4=0x40C05004 ->
        // VA_Y=0x40C06000: imm=0xFFC=4092.
        dut_e.sram0.memory[2560] = {enc_jal(5'd0, 4092), enc_addi(5'd30,5'd0,1)};
        // Page_Y @0x6000 (word 3072): low=addi x29 (hit -- still the
        // same megapage entry, VA's own vpn0=6 reconstructed), high=ebreak.
        dut_e.sram0.memory[3072] = {EBREAK_INSN, enc_addi(5'd29,5'd0,2)};

        /* ================= dut_f ================= */
        // s0=addi x1,0,8(pc0x00) s1=slli x1,x1,60(0x04) s2=addi x2,0,1(0x08)
        // s3=or x1,x1,x2(0x0C) s4=csrrw satp,x1(0x10) s5=addi x3,0,1(0x14)
        // s6=slli x3,x3,20(0x18) s7=addi x14,0,1(0x1C) s8=slli x14,x14,11(0x20)
        // s9=or x3,x3,x14(0x24) s10=csrrw mstatus,x3(0x28) s11=addi x4,0,1028(0x2C)
        // s12=slli x4,x4,20(0x30) s13=addi x15,0,3(0x34) s14=slli x15,x15,12(0x38)
        // s15=or x4,x4,x15(0x3C) s16=csrrw mepc,x4(0x40) s17=addi x6,0,256(0x44)
        // s18=csrrw mtvec,x6(0x48) s19=mret(0x4C). Each word packs
        // {HIGH(pc+4), LOW(pc+0)}.
        dut_f.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};        // {s1,s0}
        dut_f.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};           // {s3,s2}
        dut_f.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};        // {s5,s4}
        dut_f.sram0.memory[3] = {enc_addi(5'd14,5'd0,1), enc_slli(5'd3,5'd3,6'd20)};       // {s7,s6}
        dut_f.sram0.memory[4] = {enc_or(5'd3,5'd3,5'd14), enc_slli(5'd14,5'd14,6'd11)};    // {s9,s8}
        dut_f.sram0.memory[5] = {enc_addi(5'd4,5'd0,1028), enc_csrrw(`CSR_MSTATUS,5'd3)};  // {s11,s10} mstatus<-TVM=1,MPP=S
        dut_f.sram0.memory[6] = {enc_addi(5'd15,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};       // {s13,s12}
        dut_f.sram0.memory[7] = {enc_or(5'd4,5'd4,5'd15), enc_slli(5'd15,5'd15,6'd12)};    // {s15,s14} x4 = VA_X = 0x40403000
        dut_f.sram0.memory[8] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};      // {s17,s16}
        dut_f.sram0.memory[9] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};             // {s19,s18}

        // Leaf @0x4000 (word 2048): low=addi x10,x0,111 (walk#1, fills
        // TLB), high=sfence.vma (its OWN fetch is a HIT -- same VPN --
        // but its EXECUTION traps: TVM=1, S-mode -- must NOT flush).
        dut_f.sram0.memory[2048] = {SFENCE_VMA_INSN, enc_addi(5'd10,5'd0,111)};

        // Handler @0x100 (word 32 onward): capture mcause, rebuild mepc
        // to VA_X+0x100, mret back.
        handler_f[0] = enc_csrrs(`CSR_MCAUSE,5'd20);
        handler_f[1] = enc_addi(5'd26,5'd0,1028);
        handler_f[2] = enc_slli(5'd26,5'd26,6'd20);
        handler_f[3] = enc_addi(5'd27,5'd0,3);
        handler_f[4] = enc_slli(5'd27,5'd27,6'd12);
        handler_f[5] = enc_or(5'd26,5'd26,5'd27);          // x26 = VA_X base
        handler_f[6] = enc_addi(5'd26,5'd26,256);           // x26 = VA_X + 0x100
        handler_f[7] = enc_csrrw(`CSR_MEPC,5'd26);
        handler_f[8] = `INSTR_HEX_MRET;
        for (j = 0; j < 4; j = j + 1)
            dut_f.sram0.memory[32 + j] = {handler_f[2*j+1], handler_f[2*j]};
        dut_f.sram0.memory[32 + 4][31:0] = handler_f[8];

        // Phase 2 @ VA_X+0x100 (PA 0x4100, word 2080 = 0x4100/8): low=addi
        // x11,x0,222 (marker -- must HIT the still-cached TLB entry if
        // the fix holds), high=ebreak.
        dut_f.sram0.memory[2080] = {EBREAK_INSN, enc_addi(5'd11,5'd0,222)};

        dut_f.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801; // L2[1] -> L1@0x2000
        dut_f.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01; // L1[2] -> L0@0x3000
        dut_f.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0[3] -> leaf PPN=4 (PA 0x4000), full RWX

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "Sv39 TLB test never halted");

        // ---- Test A ----
        check("A: leaf code executed through both fetches (x30==1)", dut_a.core0.regfile0.gp_registers[30], 64'd1);
        check("A: exactly ONE walk -- the second (same-VPN) fetch hit", ptw_count_a, 64'd1);

        // ---- Test B ----
        check("B: page1 marker reached (x20==1)", dut_b.core0.regfile0.gp_registers[20], 64'd1);
        check("B: page2 marker reached (x21==1)", dut_b.core0.regfile0.gp_registers[21], 64'd1);
        check("B: page1 alone cost exactly one walk", ptw_count_b_mid, 64'd1);
        check("B: page2 (different VPN) added a SECOND walk", ptw_count_b, 64'd2);

        // ---- Test C ----
        check("C: VA0 marker reached (x20==1)", dut_c.core0.regfile0.gp_registers[20], 64'd1);
        check("C: VA1 marker reached (x21==1)", dut_c.core0.regfile0.gp_registers[21], 64'd1);
        check("C: VA2 marker reached (x22==1)", dut_c.core0.regfile0.gp_registers[22], 64'd1);
        check("C: VA3 marker reached (x23==1)", dut_c.core0.regfile0.gp_registers[23], 64'd1);
        check("C: VA4 marker reached (x24==1)", dut_c.core0.regfile0.gp_registers[24], 64'd1);
        check("C: VA0 revisit marker reached (x25==1)", dut_c.core0.regfile0.gp_registers[25], 64'd1);
        check("C: VA2 revisit marker reached (x26==1)", dut_c.core0.regfile0.gp_registers[26], 64'd1);
        check("C: exactly SIX walks -- VA0/1/2/3/4 + VA0's own re-walk after eviction; VA2's revisit hit", ptw_count_c, 64'd6);

        // ---- Test D ----
        check("D: walk#1's own leaf code executed (x30==1)", dut_d.core0.regfile0.gp_registers[30], 64'd1);
        check("D: walk#2's own leaf code executed (x29==2)", dut_d.core0.regfile0.gp_registers[29], 64'd2);
        check("D: SFENCE.VMA forced a genuine second walk", ptw_count_d, 64'd2);

        // ---- Test E ----
        check("E: VA_X's own leaf code executed (x30==1)", dut_e.core0.regfile0.gp_registers[30], 64'd1);
        check("E: VA_Y's own leaf code executed (x29==2)", dut_e.core0.regfile0.gp_registers[29], 64'd2);
        check("E: exactly ONE walk -- the whole megapage, both vpn0 values, cached by one entry", ptw_count_e, 64'd1);

        // ---- Test F ----
        check("F: SFENCE.VMA (TVM=1, S-mode) trapped as illegal instruction (mcause==2)", mcause_f, 64'd2);
        check("F: walk#1's own leaf marker set (x10==111)", dut_f.core0.regfile0.gp_registers[10], 64'd111);
        check({"F: phase-2 marker reached after mret (x11==222) -- proves execution resumed cleanly ",
            "post-trap"}, dut_f.core0.regfile0.gp_registers[11], 64'd222);
        check({"F: exactly ONE walk total -- the trapped SFENCE.VMA did NOT flush the TLB, so ",
            "phase-2's own access (same VPN, different offset) correctly HIT instead of re-walking"},
            ptw_count_f, 64'd1);

        $display("");
        $display("core_sv39_tlb_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_tlb_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
