// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, Sv39 Milestone 4 -- mem-side (load/store/AMO)
 * translation, via core_wb4_sram_harness. Mirrors core_sv39_fetch_tb.sv's
 * own structure/conventions exactly (same M-mode-setup idiom, same
 * hand-packed page-table construction, same scope-narrowing discipline).
 *
 * Four tests, covering the pieces genuinely new to this milestone (the
 * walker itself, its leaf-detection/superpage machinery, and the PMP-
 * after-translation two-tier ordering were all already proven by
 * core_sv39_fetch_tb.sv -- this file exercises the mem-specific
 * additions on top of that proven base):
 *   A. Load+store round trip through a translated 4KB page -- proves
 *      mem_paddr's own translated mux drives BOTH read and write bus
 *      transactions correctly.
 *   B. AMOADD.D through translation -- proves the "AMO write phase
 *      reuses the read phase's own translated PA, no second walk"
 *      design (amo_addr_q captures mem_paddr, already translated, with
 *      zero code change at the S_AMO_WRITE site).
 *   C. A page fault on a STORE to a read-only (W=0) page -- proves
 *      cause 15 (store/AMO page fault, not 13), mtval == the faulting VA.
 *   D. A PMP-denied PTE read specifically for the MEM stream (the
 *      CODE's own, separate walk succeeds; only the DATA target's own
 *      walk hits a denied PTE) -- proves cause 5 (load access fault),
 *      not 13, and proves decision 10's two-tier ordering exercised via
 *      the mem stream specifically (core_sv39_fetch_tb.sv's own test D
 *      only ever exercised it via the fetch stream).
 *
 * Originally deferred, later closed by a directed post-plan coverage
 * pass (adversarial-audit follow-up): SUM=0/1 differentiation, MXR=0/1
 * differentiation, LR through translation, and the AMO-vs-plain-load
 * page-fault classification edge case, plus the D-vs-W and A-on-a-read
 * isolations and the level-1 (megapage) misalignment case in isolation.
 * Tests E-N below (each reusing test A/C's own page-table shape and
 * M-mode-setup idiom, only the data leaf's own PTE / mem instruction /
 * an extra mstatus bit differing test to test):
 *   E. D=0 on a STORE (W=1,A=1) -- isolates the D-check from the
 *      W-check (a plain W=0 test, test C, can't tell the two apart).
 *   F. A=0 on a LOAD (R=1) -- proves A is checked on reads too.
 *   G/H. SUM=0 denies, SUM=1 permits, the SAME S-mode load off a U=1
 *      data page -- paired, both directions of one condition.
 *   I/J/K. MXR=0 denies, MXR=1 permits, the SAME S-mode load off an
 *      X=1,R=0 data page; K additionally FETCHES from that same page
 *      with MXR=0 -- proving MXR's read-only scope.
 *   L. an AMO-RMW against an R=1,W=0 page -- must fault cause 15, NOT
 *      13, direct proof of the mem_op_needs_write classification.
 *   M. LR.D against that SAME R=1,W=0 page -- must SUCCEED (LR excludes
 *      is_lr from mem_op_needs_write, unlike SC/AMO-RMW).
 *   N. a level-1 (megapage) leaf with PPN0 nonzero, PPN1 zero, in
 *      isolation (not combined with a level-2/gigapage case).
 * SC through translation remains deliberately deferred -- a mechanical
 * variation of the already-proven AMO-RMW write-phase mechanism (test B),
 * not a new one.
 */
module core_sv39_mem_tb;

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
    function automatic logic [31:0] enc_ld(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b011, rd, `OPC_LOAD);
    endfunction
    function automatic logic [31:0] enc_sd(input logic [4:0] rs2, rs1, input int imm);
        return encode_s(imm, rs2, rs1, 3'b011, `OPC_STORE);
    endfunction
    function automatic logic [31:0] enc_amoadd_d(input logic [4:0] rd, rs1, rs2);
        return encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, rs2, rs1, `FUNCT3_AMO_D, rd, `OPC_AMO);
    endfunction
    // LR.D -- rs2 field is architecturally 0 for LR, per spec.
    function automatic logic [31:0] enc_lr_d(input logic [4:0] rd, rs1);
        return encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0, rs1, `FUNCT3_AMO_D, rd, `OPC_AMO);
    endfunction
    localparam logic [31:0] EBREAK_INSN = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM};
    localparam logic [31:0] NOP_INSN    = 32'h00000013;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    /* ----------------------------------------------------------------
     * Shared page-table shape (all 4 tests): VA 0x40403000 (vpn2=1,
     * vpn1=2, vpn0=3, offset=0) -> L2@0x1000 entry1 -> L1@0x2000 entry2
     * -> L0@0x3000 entry3 -> leaf PPN=4 (PA 0x4000), the CODE page. Test
     * C additionally maps VA 0x40404000 (same vpn2/vpn1, vpn0=4) via
     * L0's own entry4 -> leaf PPN=5 (PA 0x5000), a separate DATA page.
     * Test D additionally maps VA 0x40400000 (vpn0=0) via L0's own
     * entry0, whose own PTE read is PMP-denied.
     * ---------------------------------------------------------------- */

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_a (.clk(clk), .rst(rst));
    logic halted_a = 1'b0;
    always @(posedge clk) if (dut_a.core0.trap_taken && dut_a.core0.is_ebreak) halted_a <= 1'b1;

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_b (.clk(clk), .rst(rst));
    logic halted_b = 1'b0;
    always @(posedge clk) if (dut_b.core0.trap_taken && dut_b.core0.is_ebreak) halted_b <= 1'b1;

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
     * Tests E-N: fault-taxonomy coverage closed by a directed post-plan
     * pass (adversarial-audit follow-up). All share test A/C's own
     * page-table shape (code leaf at vpn0=3/PA 0x4000, RWX=1; a SEPARATE
     * data leaf at vpn0=4/PA 0x5000 whose own PTE differs per test) and
     * M-mode-setup idiom throughout -- only the data leaf's own PTE, the
     * mem instruction under test, and (for the SUM/MXR pairs) an extra
     * mstatus bit differ test to test.
     *   E. D=0 on a STORE with A=1,W=1 -- isolates the D-check from the
     *      W-check (a plain W=0 test, already covered by test C, can't
     *      tell a "needs W" bug from a "needs D" bug apart; this can).
     *   F. A=0 on a LOAD (R=1) -- proves A is checked on reads too, not
     *      only on writes (test C/E only ever exercise it via a write).
     *   G/H. SUM=0 denies, SUM=1 permits, the SAME S-mode load off a
     *      U=1 data page -- paired, both directions of one condition.
     *   I/J/K. MXR=0 denies, MXR=1 permits, the SAME S-mode load off an
     *      X=1,R=0 data page; K additionally FETCHES from that same
     *      page with MXR=0 -- proving MXR's read-only scope.
     *   L. an AMO-RMW against an R=1,W=0 page -- must fault cause 15,
     *      NOT 13, direct proof of the mem_op_needs_write classification.
     *   M. LR.D against that SAME R=1,W=0 page -- must SUCCEED (LR
     *      excludes is_lr from mem_op_needs_write, unlike SC/AMO-RMW).
     *   N. a level-1 (megapage) leaf with PPN0 nonzero, PPN1 zero, in
     *      isolation (not combined with a level-2/gigapage case).
     * ---------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_e (.clk(clk), .rst(rst));
    logic halted_e = 1'b0;
    always @(posedge clk) if (dut_e.core0.trap_taken && dut_e.core0.is_ebreak) halted_e <= 1'b1;
    logic [63:0] mcause_e, mtval_e;
    logic        captured_e = 1'b0;
    always @(posedge clk) if (!captured_e && dut_e.core0.commit_now && dut_e.core0.pc == 64'h108) begin
        captured_e <= 1'b1;
        mcause_e   <= dut_e.core0.regfile0.gp_registers[20];
        mtval_e    <= dut_e.core0.regfile0.gp_registers[21];
    end

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

    // H (SUM=1 permit) never traps -- no capture logic needed, just the
    // defensive fallback handler at word32 (mirrors fetch_tb's test A/B).
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_h (.clk(clk), .rst(rst));
    logic halted_h = 1'b0;
    always @(posedge clk) if (dut_h.core0.trap_taken && dut_h.core0.is_ebreak) halted_h <= 1'b1;

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

    // J (MXR=1 permit) and K (fetch, MXR=0) never trap -- defensive
    // fallback handler only, same as H above.
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_j (.clk(clk), .rst(rst));
    logic halted_j = 1'b0;
    always @(posedge clk) if (dut_j.core0.trap_taken && dut_j.core0.is_ebreak) halted_j <= 1'b1;

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_k (.clk(clk), .rst(rst));
    logic halted_k = 1'b0;
    always @(posedge clk) if (dut_k.core0.trap_taken && dut_k.core0.is_ebreak) halted_k <= 1'b1;

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_l (.clk(clk), .rst(rst));
    logic halted_l = 1'b0;
    always @(posedge clk) if (dut_l.core0.trap_taken && dut_l.core0.is_ebreak) halted_l <= 1'b1;
    logic [63:0] mcause_l, mtval_l;
    logic        captured_l = 1'b0;
    always @(posedge clk) if (!captured_l && dut_l.core0.commit_now && dut_l.core0.pc == 64'h108) begin
        captured_l <= 1'b1;
        mcause_l   <= dut_l.core0.regfile0.gp_registers[20];
        mtval_l    <= dut_l.core0.regfile0.gp_registers[21];
    end

    // M (LR succeeds) never traps -- defensive fallback handler only.
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_m (.clk(clk), .rst(rst));
    logic halted_m = 1'b0;
    always @(posedge clk) if (dut_m.core0.trap_taken && dut_m.core0.is_ebreak) halted_m <= 1'b1;

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_n (.clk(clk), .rst(rst));
    logic halted_n = 1'b0;
    always @(posedge clk) if (dut_n.core0.trap_taken && dut_n.core0.is_ebreak) halted_n <= 1'b1;
    logic [63:0] mcause_n, mtval_n;
    logic        captured_n = 1'b0;
    always @(posedge clk) if (!captured_n && dut_n.core0.commit_now && dut_n.core0.pc == 64'h108) begin
        captured_n <= 1'b1;
        mcause_n   <= dut_n.core0.regfile0.gp_registers[20];
        mtval_n    <= dut_n.core0.regfile0.gp_registers[21];
    end

    wire halted = halted_a && halted_b && halted_c && halted_d
               && halted_e && halted_f && halted_g && halted_h && halted_i
               && halted_j && halted_k && halted_l && halted_m && halted_n;
    `include "halt_wait.sv"

    initial begin
        rst = 1;
        #1; // run after wb4_sram's own time-0 init

        /*
         * ---- Test A: load+store round trip ----
         * M-mode setup (0x00-0x44, 9 words) -- identical shape to
         * core_sv39_fetch_tb.sv's own test A, plus one extra ADDI
         * building the store sentinel (x8=555):
         *  0x00-0x1C: satp (MODE=Sv39,PPN=1) + mstatus (MPP=S), as before.
         *  0x20 addi x8,x0,555        (store sentinel)
         *  0x24-0x38: VA=0x40403000 built into x4, as before.
         *  0x3C csrrw mepc,x4   0x40 addi x6,x0,0x100   csrrw mtvec,x6
         *  0x44 mret
         * S-mode code @0x4000 (VA 0x40403000): sd x8,0x100(x4) ;
         * ld x30,0x100(x4) ; ebreak -- round-trips through the SAME
         * translated leaf page's own data region (PA 0x4100).
         */
        dut_a.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_a.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_a.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_a.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_a.sram0.memory[4] = {enc_addi(5'd4,5'd0,1028), enc_addi(5'd8,5'd0,555)};
        dut_a.sram0.memory[5] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_a.sram0.memory[6] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_a.sram0.memory[7] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_a.sram0.memory[8] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_a.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801; // L2 entry1 -> L1@0x2000
        dut_a.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01; // L1 entry2 -> L0@0x3000
        dut_a.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0 entry3 -> leaf PPN=4, RWX=1
        dut_a.sram0.memory[2048] = {enc_ld(5'd30,5'd4,256), enc_sd(5'd8,5'd4,256)}; // 0x4004/0x4000
        dut_a.sram0.memory[2049] = {NOP_INSN, EBREAK_INSN};                        // 0x400C/0x4008

        /*
         * ---- Test B: AMOADD.D through translation ----
         * Same satp/mstatus/mepc/mtvec/mret shape, plus x12 (= VA+0x100,
         * the AMO's own rs1 -- AMO addressing has no immediate offset)
         * and x11 (= 50, the operand). Old value 100 pre-seeded at PA
         * 0x4100; AMOADD returns the OLD value into x9 and leaves
         * 100+50=150 at the SAME physical location -- reloaded via an
         * ordinary LD (x30) to prove the write phase landed at the
         * correct, translated address with no second walk.
         */
        dut_b.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_b.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_b.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_b.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_b.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_b.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_b.sram0.memory[6] = {enc_addi(5'd12,5'd4,256), enc_or(5'd4,5'd4,5'd5)};
        dut_b.sram0.memory[7] = {enc_csrrw(`CSR_MEPC,5'd4), enc_addi(5'd11,5'd0,50)};
        dut_b.sram0.memory[8] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_b.sram0.memory[9] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_b.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_b.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_b.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_b.sram0.memory[2048] = {enc_ld(5'd30,5'd12,0), enc_amoadd_d(5'd9,5'd12,5'd11)}; // 0x4004/0x4000
        dut_b.sram0.memory[2049] = {NOP_INSN, EBREAK_INSN};
        dut_b.sram0.memory[2080] = 64'd100; // PA 0x4100 -- AMO's own OLD value

        /*
         * ---- Test C: store page fault (W=0), cause 15 ----
         * CODE stays on the vpn0=3 leaf (RWX=1, as tests A/B). A SEPARATE
         * leaf at vpn0=4 (VA 0x40404000, PA 0x5000) is mapped READ-ONLY
         * (R=1,W=0,X=0) via L0's own entry4 -- the store below targets
         * THAT page, not the code page, so X/W don't conflict with
         * fetch's own need for X=1 on the code page. x13 = VA
         * 0x40404000 (no low-order OR needed -- offset=0, vpn1/vpn0 both
         * exactly represented by a single shift).
         */
        dut_c.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_c.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_c.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_c.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_c.sram0.memory[4] = {enc_slli(5'd13,5'd13,6'd20), enc_addi(5'd13,5'd0,1028)};
        dut_c.sram0.memory[5] = {enc_slli(5'd14,5'd14,6'd12), enc_addi(5'd14,5'd0,4)};
        dut_c.sram0.memory[6] = {enc_addi(5'd4,5'd0,1028), enc_or(5'd13,5'd13,5'd14)};
        dut_c.sram0.memory[7] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_c.sram0.memory[8] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_c.sram0.memory[9] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_c.sram0.memory[10] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_c.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_c.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_c.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0 entry3 (code) -> PPN=4, RWX=1
        dut_c.sram0.memory[1536 + 4] = 64'h0000_0000_0000_1443; // L0 entry4 (data) -> PPN=5, R=1,W=0,X=0
        dut_c.sram0.memory[2048] = {EBREAK_INSN, enc_sd(5'd0,5'd13,0)}; // 0x4004=ebreak(unreached), 0x4000=sd x0,0(x13)
        dut_c.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_c.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        /*
         * ---- Test D: PMP-denied PTE read, mem stream, cause 5 ----
         * CODE's own walk (vpn0=3, as always) is fully permitted. A
         * SEPARATE, unrelated leaf at vpn0=0 (VA 0x40400000) is mapped
         * via L0's own entry0 (byte address 0x3000 exactly -- the
         * SAME address as L0's own table base, a harmless coincidence
         * of using index 0) -- content is irrelevant, since PMP denies
         * reading this ONE PTE before its content is ever consulted.
         * region0: TOR [0,0x3000), R=1 (permits L2/L1's own PTEs, both
         * < 0x3000; M-mode's own setup-code fetch is separately exempt
         * regardless, since this region is unlocked).
         * region1: TOR [0x3000,0x3008), R=0 -- denies ONLY entry0.
         * region2: TOR [0x3008, big), R=1 AND X=1 -- permits entry3's
         * own PTE read (0x3018) AND, separately, the CODE leaf's own
         * TRANSLATED fetch (PA 0x4000 also falls in this same region --
         * a real, empirically-caught test-design gap: PMP is one flat
         * region set governing BOTH a PTE read and the final resolved
         * address per decision 10's own two-tier ordering, so granting
         * only R here [enough for the PTE read] left the CODE's own
         * post-translation fetch denied by the EXISTING, already-proven
         * fetch-side PMP check -- X had to be added too).
         */
        dut_d.sram0.memory[0]  = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};        // 0x04/0x00
        dut_d.sram0.memory[1]  = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};           // 0x0C/0x08
        dut_d.sram0.memory[2]  = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};        // 0x14/0x10
        dut_d.sram0.memory[3]  = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)}; // 0x1C/0x18
        dut_d.sram0.memory[4]  = {enc_slli(5'd7,5'd7,6'd10), enc_addi(5'd7,5'd0,3)};        // 0x24/0x20 -- x7=3072=pmpaddr0
        dut_d.sram0.memory[5]  = {enc_addi(5'd8,5'd7,2), enc_csrrw(`CSR_PMPADDR0,5'd7)};    // 0x2C/0x28 -- x8=3074=pmpaddr1
        dut_d.sram0.memory[6]  = {enc_addi(5'd9,5'd0,2), enc_csrrw(`CSR_PMPADDR1,5'd8)};    // 0x34/0x30
        dut_d.sram0.memory[7]  = {enc_csrrw(`CSR_PMPADDR2,5'd9), enc_slli(5'd9,5'd9,6'd12)}; // 0x3C/0x38 -- x9=8192=pmpaddr2
        dut_d.sram0.memory[8]  = {enc_addi(5'd11,5'd0,8), enc_addi(5'd10,5'd0,9)};          // 0x44/0x40 -- region0 byte=9, region1 byte=8
        dut_d.sram0.memory[9]  = {enc_or(5'd10,5'd10,5'd11), enc_slli(5'd11,5'd11,6'd8)};   // 0x4C/0x48
        dut_d.sram0.memory[10] = {enc_slli(5'd12,5'd12,6'd16), enc_addi(5'd12,5'd0,13)};    // 0x54/0x50 -- region2 byte=13 (TOR,X=1,R=1)
        dut_d.sram0.memory[11] = {enc_csrrw(`CSR_PMPCFG0,5'd10), enc_or(5'd10,5'd10,5'd12)}; // 0x5C/0x58
        dut_d.sram0.memory[12] = {enc_slli(5'd13,5'd13,6'd20), enc_addi(5'd13,5'd0,1028)};  // 0x64/0x60 -- x13=0x40400000
        dut_d.sram0.memory[13] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};     // 0x6C/0x68
        dut_d.sram0.memory[14] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};        // 0x74/0x70
        dut_d.sram0.memory[15] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};       // 0x7C/0x78 -- x4=0x40403000
        dut_d.sram0.memory[16] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};     // 0x84/0x80
        dut_d.sram0.memory[17] = {NOP_INSN, `INSTR_HEX_MRET};                               // 0x8C(pad)/0x88
        dut_d.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_d.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_d.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0 entry3 (code) -> PPN=4, RWX=1
        // L0 entry0 (word 1536) left 0 -- PMP denies its own read anyway.
        dut_d.sram0.memory[2048] = {EBREAK_INSN, enc_ld(5'd30,5'd13,0)}; // 0x4004=ebreak(unreached), 0x4000=ld x30,0(x13)
        dut_d.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_d.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        /*
         * ---- Test E: D=0 on a STORE (W=1,A=1) -- isolates the D-check
         * from the W-check. Same word0-10 M-mode setup as test C (builds
         * BOTH x13=VA_data=0x40404000 and x4=VA_code=0x40403000). L0
         * entry4 = V=R=W=A=1, D=0, PPN=5. S-code: sd x0,0(x13) (same
         * store test C already uses, target page differs only in D).
         */
        dut_e.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_e.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_e.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_e.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_e.sram0.memory[4] = {enc_slli(5'd13,5'd13,6'd20), enc_addi(5'd13,5'd0,1028)};
        dut_e.sram0.memory[5] = {enc_slli(5'd14,5'd14,6'd12), enc_addi(5'd14,5'd0,4)};
        dut_e.sram0.memory[6] = {enc_addi(5'd4,5'd0,1028), enc_or(5'd13,5'd13,5'd14)};
        dut_e.sram0.memory[7] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_e.sram0.memory[8] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_e.sram0.memory[9] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_e.sram0.memory[10] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_e.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_e.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_e.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // code leaf, PPN=4
        dut_e.sram0.memory[1536 + 4] = 64'h0000_0000_0000_1447; // data leaf: V=R=W=A=1, D=0, PPN=5
        dut_e.sram0.memory[2048] = {EBREAK_INSN, enc_sd(5'd0,5'd13,0)};
        dut_e.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_e.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        /*
         * ---- Test F: A=0 on a LOAD (R=1) -- proves A is checked on
         * reads too, independent of D/write-ness. Same setup shape as
         * test E; L0 entry4 = V=R=1 only (A=0, D=0, W=0, X=0). S-code:
         * ld x30,0(x13).
         */
        dut_f.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_f.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_f.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_f.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_f.sram0.memory[4] = {enc_slli(5'd13,5'd13,6'd20), enc_addi(5'd13,5'd0,1028)};
        dut_f.sram0.memory[5] = {enc_slli(5'd14,5'd14,6'd12), enc_addi(5'd14,5'd0,4)};
        dut_f.sram0.memory[6] = {enc_addi(5'd4,5'd0,1028), enc_or(5'd13,5'd13,5'd14)};
        dut_f.sram0.memory[7] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_f.sram0.memory[8] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_f.sram0.memory[9] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_f.sram0.memory[10] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_f.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_f.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_f.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_f.sram0.memory[1536 + 4] = 64'h0000_0000_0000_1403; // data leaf: V=R=1 only, A=0, PPN=5
        dut_f.sram0.memory[2048] = {EBREAK_INSN, enc_ld(5'd30,5'd13,0)};
        dut_f.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_f.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        /*
         * ---- Test G: SUM=0 denies an S-mode load off a U=1 data page
         * (V=R=W=U=A=D=1, PPN=5). Same setup shape as test E/F, mstatus
         * only ever sets MPP=S (SUM stays 0). S-code: ld x30,0(x13).
         */
        dut_g.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_g.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_g.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_g.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_g.sram0.memory[4] = {enc_slli(5'd13,5'd13,6'd20), enc_addi(5'd13,5'd0,1028)};
        dut_g.sram0.memory[5] = {enc_slli(5'd14,5'd14,6'd12), enc_addi(5'd14,5'd0,4)};
        dut_g.sram0.memory[6] = {enc_addi(5'd4,5'd0,1028), enc_or(5'd13,5'd13,5'd14)};
        dut_g.sram0.memory[7] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_g.sram0.memory[8] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_g.sram0.memory[9] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_g.sram0.memory[10] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_g.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_g.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_g.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_g.sram0.memory[1536 + 4] = 64'h0000_0000_0000_14D7; // data leaf: V=R=W=U=A=D=1, PPN=5
        dut_g.sram0.memory[2048] = {EBREAK_INSN, enc_ld(5'd30,5'd13,0)};
        dut_g.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_g.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        /*
         * ---- Test H: SUM=1 permits the IDENTICAL access (companion to
         * G). Same U=1 data leaf; mstatus additionally ORs in SUM (bit
         * 18) via x8 before the mstatus write. Never traps -- x30 is
         * loaded from a preseeded sentinel (777) at PA 0x5000.
         */
        dut_h.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_h.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_h.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_h.sram0.memory[3] = {enc_addi(5'd8,5'd0,1), enc_slli(5'd3,5'd3,6'd11)};
        dut_h.sram0.memory[4] = {enc_or(5'd3,5'd3,5'd8), enc_slli(5'd8,5'd8,6'd18)};
        dut_h.sram0.memory[5] = {enc_addi(5'd13,5'd0,1028), enc_csrrw(`CSR_MSTATUS,5'd3)};
        dut_h.sram0.memory[6] = {enc_addi(5'd14,5'd0,4), enc_slli(5'd13,5'd13,6'd20)};
        dut_h.sram0.memory[7] = {enc_or(5'd13,5'd13,5'd14), enc_slli(5'd14,5'd14,6'd12)};
        dut_h.sram0.memory[8] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_h.sram0.memory[9] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_h.sram0.memory[10] = {enc_addi(5'd6,5'd0,256), enc_or(5'd4,5'd4,5'd5)};
        dut_h.sram0.memory[11] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_h.sram0.memory[12] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_h.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_h.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_h.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_h.sram0.memory[1536 + 4] = 64'h0000_0000_0000_14D7; // same U=1 data leaf as test G
        dut_h.sram0.memory[2048] = {EBREAK_INSN, enc_ld(5'd30,5'd13,0)};
        dut_h.sram0.memory[2560] = 64'd777; // PA 0x5000 (word = 0x5000/8) -- sentinel the load must return

        /*
         * ---- Test I: MXR=0 denies a load from an X=1,R=0 data leaf
         * (V=X=A=D=1, PPN=5). Same setup shape as test E/F/G. S-code:
         * ld x30,0(x13).
         */
        dut_i.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_i.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_i.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_i.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_i.sram0.memory[4] = {enc_slli(5'd13,5'd13,6'd20), enc_addi(5'd13,5'd0,1028)};
        dut_i.sram0.memory[5] = {enc_slli(5'd14,5'd14,6'd12), enc_addi(5'd14,5'd0,4)};
        dut_i.sram0.memory[6] = {enc_addi(5'd4,5'd0,1028), enc_or(5'd13,5'd13,5'd14)};
        dut_i.sram0.memory[7] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_i.sram0.memory[8] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_i.sram0.memory[9] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_i.sram0.memory[10] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_i.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_i.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_i.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_i.sram0.memory[1536 + 4] = 64'h0000_0000_0000_14C9; // data leaf: V=X=A=D=1, R=0, PPN=5
        dut_i.sram0.memory[2048] = {EBREAK_INSN, enc_ld(5'd30,5'd13,0)};
        dut_i.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_i.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        /*
         * ---- Test J: MXR=1 permits the IDENTICAL load (companion to
         * I) -- same X=1,R=0 leaf; mstatus additionally ORs in MXR (bit
         * 19). Never traps -- x30 loaded from a preseeded sentinel (888).
         */
        dut_j.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_j.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_j.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_j.sram0.memory[3] = {enc_addi(5'd8,5'd0,1), enc_slli(5'd3,5'd3,6'd11)};
        dut_j.sram0.memory[4] = {enc_or(5'd3,5'd3,5'd8), enc_slli(5'd8,5'd8,6'd19)};
        dut_j.sram0.memory[5] = {enc_addi(5'd13,5'd0,1028), enc_csrrw(`CSR_MSTATUS,5'd3)};
        dut_j.sram0.memory[6] = {enc_addi(5'd14,5'd0,4), enc_slli(5'd13,5'd13,6'd20)};
        dut_j.sram0.memory[7] = {enc_or(5'd13,5'd13,5'd14), enc_slli(5'd14,5'd14,6'd12)};
        dut_j.sram0.memory[8] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_j.sram0.memory[9] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_j.sram0.memory[10] = {enc_addi(5'd6,5'd0,256), enc_or(5'd4,5'd4,5'd5)};
        dut_j.sram0.memory[11] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_j.sram0.memory[12] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_j.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_j.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_j.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_j.sram0.memory[1536 + 4] = 64'h0000_0000_0000_14C9; // same X=1,R=0 data leaf as test I
        dut_j.sram0.memory[2048] = {EBREAK_INSN, enc_ld(5'd30,5'd13,0)};
        dut_j.sram0.memory[2560] = 64'd888; // PA 0x5000 (word = 0x5000/8) -- sentinel the load must return

        /*
         * ---- Test K: a FETCH from that SAME X=1,R=0 leaf succeeds
         * regardless of MXR (stays 0 here) -- proves MXR's read-only
         * scope. No code page at all: mepc is set DIRECTLY to the data
         * VA (0x40404000), so the CPU fetches from PA 0x5000, where a
         * real instruction sequence is placed (addi x30,x0,999; ebreak).
         */
        dut_k.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_k.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_k.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_k.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_k.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_k.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,4)};
        dut_k.sram0.memory[6] = {enc_addi(5'd6,5'd0,256), enc_or(5'd4,5'd4,5'd5)};
        dut_k.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_k.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_k.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_k.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_k.sram0.memory[1536 + 4] = 64'h0000_0000_0000_14C9; // data/fetch leaf: V=X=A=D=1, R=0, PPN=5
        dut_k.sram0.memory[2560] = {EBREAK_INSN, enc_addi(5'd30,5'd0,999)}; // PA 0x5000/0x5004 (word = 0x5000/8)

        /*
         * ---- Test L: an AMO-RMW (AMOADD.D) against an R=1,W=0 leaf
         * must fault cause 15 (store/AMO page fault), NOT 13 -- direct
         * proof of the mem_op_needs_write-based classification (is_amo_rmw
         * is included, unlike is_lr). Same setup shape as test E/F/G/I.
         */
        dut_l.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_l.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_l.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_l.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_l.sram0.memory[4] = {enc_slli(5'd13,5'd13,6'd20), enc_addi(5'd13,5'd0,1028)};
        dut_l.sram0.memory[5] = {enc_slli(5'd14,5'd14,6'd12), enc_addi(5'd14,5'd0,4)};
        dut_l.sram0.memory[6] = {enc_addi(5'd4,5'd0,1028), enc_or(5'd13,5'd13,5'd14)};
        dut_l.sram0.memory[7] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_l.sram0.memory[8] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_l.sram0.memory[9] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_l.sram0.memory[10] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_l.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_l.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_l.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_l.sram0.memory[1536 + 4] = 64'h0000_0000_0000_14C3; // data leaf: V=R=A=D=1, W=0, PPN=5
        dut_l.sram0.memory[2048] = {enc_amoadd_d(5'd9,5'd13,5'd11), enc_addi(5'd11,5'd0,50)};
        dut_l.sram0.memory[2049] = {NOP_INSN, EBREAK_INSN};
        dut_l.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_l.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        /*
         * ---- Test M: LR.D against the SAME R=1,W=0 leaf SUCCEEDS
         * (companion to L) -- LR excludes is_lr from mem_op_needs_write,
         * so it only ever needs R, unlike SC/AMO-RMW. Never traps -- x30
         * is loaded from a preseeded sentinel (555) at PA 0x5000.
         */
        dut_m.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_m.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_m.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_m.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_m.sram0.memory[4] = {enc_slli(5'd13,5'd13,6'd20), enc_addi(5'd13,5'd0,1028)};
        dut_m.sram0.memory[5] = {enc_slli(5'd14,5'd14,6'd12), enc_addi(5'd14,5'd0,4)};
        dut_m.sram0.memory[6] = {enc_addi(5'd4,5'd0,1028), enc_or(5'd13,5'd13,5'd14)};
        dut_m.sram0.memory[7] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_m.sram0.memory[8] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_m.sram0.memory[9] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_m.sram0.memory[10] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_m.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_m.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_m.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_m.sram0.memory[1536 + 4] = 64'h0000_0000_0000_14C3; // same R=1,W=0 data leaf as test L
        dut_m.sram0.memory[2048] = {EBREAK_INSN, enc_lr_d(5'd30,5'd13)};
        dut_m.sram0.memory[2560] = 64'd555; // PA 0x5000 (word = 0x5000/8) -- sentinel LR.D must return

        /*
         * ---- Test N: a level-1 (megapage) leaf with PPN0=1 (nonzero),
         * PPN1=0 -- misaligned in isolation, not combined with a
         * level-2/gigapage case. L1 entry2 (vpn1=2) IS the leaf itself
         * (V=R=W=X=A=D=1, misaligned PPN0=1); a SEPARATE L1 entry5
         * (vpn1=5) still points down to a real, valid 4KB code page, so
         * the CODE's own fetch (a DIFFERENT vpn1 index) is unaffected --
         * code VA=0x40A00000 (vpn2=1,vpn1=5,vpn0=0); target/faulting VA
         * =0x40400000 (vpn2=1,vpn1=2,vpn0=0,off=0), same L2/L1 table.
         */
        dut_n.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_n.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_n.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_n.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_n.sram0.memory[4] = {enc_slli(5'd13,5'd13,6'd20), enc_addi(5'd13,5'd0,1028)};
        dut_n.sram0.memory[5] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1034)};
        dut_n.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_addi(5'd6,5'd0,256)};
        dut_n.sram0.memory[7] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_n.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;  // L2 entry1 -> L1@0x2000
        dut_n.sram0.memory[1024 + 2] = 64'h0000_0000_0000_04CF; // L1 entry2 IS the leaf: PPN0=1 (misaligned), PPN1=0
        dut_n.sram0.memory[1024 + 5] = 64'h0000_0000_0000_0C01; // L1 entry5 -> L0@0x3000 (code, unaffected)
        dut_n.sram0.memory[1536 + 0] = 64'h0000_0000_0000_10CF; // L0 entry0 -> code leaf, PPN=4
        dut_n.sram0.memory[2048] = {EBREAK_INSN, enc_ld(5'd30,5'd13,0)};
        dut_n.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_n.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "Sv39 mem walker test never halted");

        check("A: store+load round trip through translation (x30==555)",
              dut_a.core0.regfile0.gp_registers[30], 64'd555);

        check("B: AMOADD.D returns the OLD value (x9==100)", dut_b.core0.regfile0.gp_registers[9], 64'd100);
        check("B: AMOADD.D's write phase landed the NEW value at the translated PA (x30==150)",
              dut_b.core0.regfile0.gp_registers[30], 64'd150);

        check("C: store to a read-only page produces mcause==15 (store/AMO page fault)", mcause_c, 64'd15);
        check("C: mtval == the faulting VIRTUAL address", mtval_c, 64'h40404000);

        check("D: PMP-denied PTE read (mem stream) produces mcause==5 (load access fault), NOT 13",
              mcause_d, 64'd5);
        check("D: mtval == the faulting instruction's own VA (not the PTE's PA)", mtval_d, 64'h40400000);

        check("E: D=0 on a store (W=1,A=1) produces mcause==15, isolated from the W-check", mcause_e, 64'd15);
        check("E: mtval == the faulting VIRTUAL address", mtval_e, 64'h40404000);

        check("F: A=0 on a load (R=1) produces mcause==13, checked independent of D/write-ness", mcause_f, 64'd13);
        check("F: mtval == the faulting VIRTUAL address", mtval_f, 64'h40404000);

        check("G: SUM=0 denies an S-mode load off a U=1 page, mcause==13", mcause_g, 64'd13);
        check("G: mtval == the faulting VIRTUAL address", mtval_g, 64'h40404000);

        check("H: SUM=1 permits the IDENTICAL access (x30==777, no trap)",
              dut_h.core0.regfile0.gp_registers[30], 64'd777);

        check("I: MXR=0 denies a load from an X=1,R=0 page, mcause==13", mcause_i, 64'd13);
        check("I: mtval == the faulting VIRTUAL address", mtval_i, 64'h40404000);

        check("J: MXR=1 permits the IDENTICAL load (x30==888, no trap)",
              dut_j.core0.regfile0.gp_registers[30], 64'd888);

        check("K: a FETCH from that SAME X=1,R=0 page succeeds regardless of MXR (x30==999, no trap) -- proves MXR's load-only scope",
              dut_k.core0.regfile0.gp_registers[30], 64'd999);

        check("L: an AMO-RMW against an R=1,W=0 page produces mcause==15, NOT 13 -- proves the mem_op_needs_write classification", mcause_l, 64'd15);
        check("L: mtval == the faulting VIRTUAL address", mtval_l, 64'h40404000);
        check("L: AMO dest register unchanged (no writeback -- faulted before commit)", dut_l.core0.regfile0.gp_registers[9], 64'd0);

        check("M: LR.D against that SAME R=1,W=0 page SUCCEEDS (x30==555, no trap) -- LR excludes is_lr from mem_op_needs_write",
              dut_m.core0.regfile0.gp_registers[30], 64'd555);

        check("N: a level-1 (megapage) leaf with PPN0 nonzero, PPN1 zero, in isolation faults, mcause==13", mcause_n, 64'd13);
        check("N: mtval == the faulting VIRTUAL address", mtval_n, 64'h40400000);

        $display("");
        $display("core_sv39_mem_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_mem_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
