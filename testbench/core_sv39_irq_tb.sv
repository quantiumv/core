// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: the interrupt-entry fetch redirect (Sv39/PMP/debug-halt
 * combined regression)
 *
 * Regression for a real, pre-existing bug (not caused by any pipelining
 * work): in the interrupt cycle `t` (`interrupt_taken`, the first S_FETCH
 * cycle after a commit -- `pc <= trap_vector` and the privilege switch
 * happen on that SAME edge), the fetch side used to still act on the OLD
 * `pc` under the OLD privilege (TLB lookup/resolve, walk-start, PMP-fault
 * exit), and `fetch_redirect_q`/`fetch_from_trap_vector` then forced a raw,
 * UNTRANSLATED `trap_vector` onto the fetch bus for as long as that stale
 * fetch took to complete. Under Sv39, an interrupt delegated to S-mode
 * fetched its handler's first instruction from PHYSICAL `mtvec` instead of
 * translated `stvec`. Fixed by making the fetch side do nothing at all in
 * cycle `t` (see design/core.sv's own `fetch_redirect_cycle` declaration
 * comment) -- the handler fetch starts the ordinary way at `t+1`, from the
 * already-redirected `pc` under the already-switched privilege.
 *
 * Every case below is run and confirmed to FAIL against the pre-fix RTL
 * (revert-and-recheck) before being trusted as a real regression test, not
 * just written to pass.
 *
 * Page-table shape for every Sv39 case (identical to
 * core_sv39_fetch_tb.sv's own test A, reused verbatim): a real 3-level walk,
 * VA 0x40403000 (vpn2=1,vpn1=2,vpn0=3) -> PA 0x4000, L2@0x1000/L1@0x2000/
 * L0@0x3000 (words 512/1024/1536), leaf RWXAD=1,U=0 (test A/B) or U=1 (test
 * D, S-mode-owned code).
 *
 *   A. S-mode SEI, delegated (mideleg[9]=1), Sv39 active: the handler at
 *      stvec (VA, same page as mepc) must run -- proves the fix directly,
 *      the exact case that motivated it.
 *   B. M-mode MTI (never delegated), pending from before Sv39 even starts,
 *      taken the instant a JALR lands on an UNMAPPED VA (no walk for
 *      `interrupt_taken`'s own cycle could ever succeed) -- proves `mepc`
 *      is the real fetch target, not corrupted by a spurious walk of it.
 *   C. Bare mode (satp.MODE=0), U-mode, MTI pending, taken the instant a
 *      JALR lands on a PMP-DENIED address -- proves `mepc`/`mcause` aren't
 *      overwritten by a spurious access fault at `mtvec`.
 *   D1. Sv39 S-mode loop halted via `i_debug_halt_req`; `dpc` is poked
 *      (direct backdoor register write, same convention core_debug_halt_tb.sv
 *      already establishes for `dpc_q`) to a DIFFERENT mapped VA before
 *      resume -- the resumed fetch must come from the NEW `dpc`, not a
 *      stale resolve of the OLD one.
 *   D2. Same halt, but `dpc` UNCHANGED and instead the loop's own leaf PTE
 *      is remapped (plus the TLB force-invalidated -- no SFENCE.VMA can
 *      execute while halted) while parked -- the resumed fetch must use
 *      the NEW mapping, not a stale TLB-resolved translation of the old one.
 */
module core_sv39_irq_tb;

    logic clk = 0;
    always #5 clk = ~clk;

    localparam logic [2:0] FUNCT3_OR  = 3'b110;
    localparam logic [6:0] FUNCT7_OR  = 7'b0000000;
    function automatic logic [31:0] enc_or(input logic [4:0] rd, rs1, rs2);
        return encode_r(FUNCT7_OR, rs2, rs1, FUNCT3_OR, rd, `OPC_OP);
    endfunction
    function automatic logic [31:0] enc_addi(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b000, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_ori(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b110, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_slli(input logic [4:0] rd, rs1, input logic [5:0] shamt);
        return encode_shift64(6'b0, shamt, rs1, 3'b001, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_jalr(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b000, rd, `OPC_JALR);
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
     * Test A: S-mode SEI, delegated, Sv39 active.
     * M-mode setup: satp (L2 PPN=1), mideleg[9]=1 (SEI), sie.SEIE=1,
     * mstatus.MPP=S + SIE=1 directly (so sstatus.SIE=1 the instant mret
     * lands in S-mode -- mret never propagates SPIE->SIE, only sret does),
     * mepc=VA 0x40403000, stvec=VA 0x40404000 (a FULL page apart, so they
     * resolve through genuinely SEPARATE L0 entries -- +0x100 would stay
     * on mepc's own page, aliasing into unmapped bytes just past its own
     * code, a real bug this test itself first shipped with). mtvec = PA
     * 0x100 (a distinct,
     * never-legitimately-reached fallback marker).
     * ---------------------------------------------------------------- */
    logic rst_a = 1;
    logic seip_a = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_a (.clk(clk), .rst(rst_a), .i_seip(seip_a));
    // poison_trap_a: NOT a completion signal (the real handler/loop targets
    // spin forever, they never ebreak -- see their own code comments for
    // why) -- this only ever latches if something reaches a defensive
    // fallback/poison marker that should be structurally unreachable.
    logic poison_trap_a = 1'b0;
    always @(posedge clk) if (dut_a.core0.trap_taken && dut_a.core0.is_ebreak) poison_trap_a <= 1'b1;

    /* ----------------------------------------------------------------
     * Test B: M-mode MTI, never delegated, taken the instant a JALR lands
     * on an unmapped VA (0x40404000 -- same L2/L1 as the mapped page, but
     * L0 entry 4 is left zero, V=0). mie.MTIE is set during M-mode setup
     * (mti_pending needs mie&mip together, regardless of privilege) but
     * i_mtip_b itself is asserted only on the JALR's OWN commit (see its
     * trigger, declared alongside dut_b's instantiation) -- NOT before
     * reset: mti_enabled is unconditionally true below M the instant mret
     * drops into S-mode (per its own current_priv!=PRIV_M term), so
     * asserting i_mtip_b any earlier would make interrupt_taken fire on
     * mepc itself (a real, mapped VA) instead of on the JALR's unmapped
     * target, missing the scenario this test exists to exercise. Landing
     * exactly in the window this bug hits: the OLD code's fetch-side
     * machinery would act on the unmapped VA's stale pre-redirect state
     * (attempting a real walk of it) before ever reaching mtvec as a
     * genuine fetch. mtvec = PA 0x100 (fallback marker, must never be
     * reached: an interrupt taken from M-mode is never delegated regardless of
     * mideleg, so this is really just proving mepc/mcause survive intact).
     * ---------------------------------------------------------------- */
    logic rst_b = 1;
    logic i_mtip_b = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_b (.clk(clk), .rst(rst_b), .i_mtip(i_mtip_b));
    // Asserted on the JALR's own commit (VA 0x40403000, the S-mode entry
    // point -- pc is always virtual, never the PA its bytes live at) --
    // NOT before reset. mti_pending && mti_enabled becomes
    // unconditionally true the instant we're in S-mode (mti_enabled's own
    // current_priv!=PRIV_M term), so asserting i_mtip_b any earlier makes
    // interrupt_taken fire on mepc itself (a real, mapped VA -- see test
    // B's own header comment) instead of on the JALR's unmapped TARGET,
    // missing the scenario this test exists to exercise (confirmed: an
    // earlier draft that asserted i_mtip_b before reset passed on BOTH
    // pre-fix and post-fix core.sv, providing zero regression coverage).
    // pc is always the VIRTUAL address (0x40403000), never the physical
    // one (0x4000) its bytes happen to be stored at -- a real mistake an
    // earlier version of this trigger had, confirmed by simulation (the
    // trigger silently never fired at all, and the resulting page fault
    // was just the JALR's own genuinely-unmapped target faulting
    // ordinarily, with no interrupt involved).
    always @(posedge clk) if (dut_b.core0.commit_now && dut_b.core0.pc == 64'h40403000) i_mtip_b <= 1'b1;
    // poison_trap_b: see poison_trap_a's own comment above.
    logic poison_trap_b = 1'b0;
    always @(posedge clk) if (dut_b.core0.trap_taken && dut_b.core0.is_ebreak) poison_trap_b <= 1'b1;

    /* ----------------------------------------------------------------
     * Test C: bare mode (no Sv39 at all), U-mode, MTI pending, taken the
     * instant a JALR lands on a PMP-denied address (0x2000, TOR-denied by
     * pmpaddr0/pmpcfg0). Proves the fix's gating (fetch_redirect_cycle)
     * doesn't depend on Sv39 being active -- the SAME stale-pc mechanism
     * hits fstate_lo_denied_now's own PMP-deny capture just as it hits the
     * translated walker path in tests A/B.
     * ---------------------------------------------------------------- */
    logic rst_c = 1;
    logic i_mtip_c = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_c (.clk(clk), .rst(rst_c), .i_mtip(i_mtip_c));
    // poison_trap_c: see poison_trap_a's own comment above.
    logic poison_trap_c = 1'b0;
    always @(posedge clk) if (dut_c.core0.trap_taken && dut_c.core0.is_ebreak) poison_trap_c <= 1'b1;

    /* ----------------------------------------------------------------
     * Test D1/D2: Sv39 S-mode, halted via i_debug_halt_req while looping,
     * resumed after the debugger changes where/what the loop's own next
     * fetch must resolve to. Same page table as A/B (VA 0x40403000 ->
     * PA 0x4000, U=0 -- S-mode can never execute from a U=1 page, unlike
     * data access, there is no SUM-equivalent permission for fetch, per
     * ptw_u_violation's own !ptw_is_mem term). D1's new target VA
     * 0x40404000 -- a FULL page past the loop's own VA, so it resolves
     * through the SAME L2/L1 (word 512/1024) to a genuinely SEPARATE,
     * independently-walked L0 entry (word 1536+4); +0x100 would stay on
     * the loop's own page, aliasing into unmapped bytes just past its own
     * code, the exact same real bug test A's own stvec construction first
     * shipped with. D2 leaves
     * dpc alone and instead overwrites the ORIGINAL leaf PTE's own PPN.
     * ---------------------------------------------------------------- */
    logic rst_d1 = 1;
    logic halt_req_d1 = 1'b0;
    logic resume_req_d1 = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_d1 (
        .clk(clk), .rst(rst_d1),
        .i_debug_halt_req(halt_req_d1), .i_debug_resume_req(resume_req_d1)
    );

    logic rst_d2 = 1;
    logic halt_req_d2 = 1'b0;
    logic resume_req_d2 = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_d2 (
        .clk(clk), .rst(rst_d2),
        .i_debug_halt_req(halt_req_d2), .i_debug_resume_req(resume_req_d2)
    );

    // poison_trap_d1/d2: see poison_trap_a's own comment above -- D1/D2's
    // own post-resume targets also spin forever now, not ebreak; this only
    // latches on their M-mode fallback marker (word32), which is still a
    // genuine "should never be reached" negative check.
    logic poison_trap_d1 = 1'b0;
    logic poison_trap_d2 = 1'b0;
    always @(posedge clk) if (dut_d1.core0.trap_taken && dut_d1.core0.is_ebreak) poison_trap_d1 <= 1'b1;
    always @(posedge clk) if (dut_d2.core0.trap_taken && dut_d2.core0.is_ebreak) poison_trap_d2 <= 1'b1;

    // Fixed, generous settle delays -- NOT ebreak-gated (every real target
    // spins forever on its own success path; only a genuine failure would
    // ever reach an actual trap) -- sized well past setup (~25 short
    // instructions) + a real 3-level Sv39 walk (~15-20 cycles) + the
    // handler's own few instructions, for every case below.
    localparam int SETTLE_CYCLES        = 400;
    localparam int RESUME_SETTLE_CYCLES = 150;

    initial begin
        #1; // run after wb4_sram's own time-0 init

        /* ==== Test A program ==== */
        // 0x00 addi x1,x0,8      0x04 slli x1,x1,60      (x1 = satp MODE)
        // 0x08 addi x2,x0,1      0x0C or   x1,x1,x2       (x2 = L2 PPN=1)
        // 0x10 csrrw satp,x1     0x14 addi x7,x0,1
        // 0x18 slli x7,x7,9      0x1C csrrw mideleg,x7    (delegate SEI)
        // 0x20 csrrw sie,x7      0x24 addi x3,x0,1
        // 0x28 slli x3,x3,11     0x2C ori  x3,x3,2         (mstatus: MPP=S(1<<11), SIE=1(1<<1) --
        //                                                   mret does NOT propagate SPIE->SIE, unlike
        //                                                   sret, so SIE needs setting directly here)
        // 0x30 csrrw mstatus,x3  0x34 addi x4,x0,0x404
        // 0x38 slli x4,x4,20     0x3C addi x5,x0,3
        // 0x40 slli x5,x5,12     0x44 or   x4,x4,x5        (x4 = VA 0x40403000)
        // 0x48 csrrw mepc,x4     0x4C addi x8,x0,0x404
        // 0x50 slli x8,x8,20     0x54 addi x11,x0,4
        // 0x58 slli x11,x11,12   0x5C or   x8,x8,x11        (x8 = VA 0x40404000 = stvec --
        //                                                    a FULL page past mepc's own VA,
        //                                                    landing on a genuinely SEPARATE L0
        //                                                    entry; +0x100 would stay on mepc's
        //                                                    own page, aliasing into unmapped
        //                                                    bytes just past its own code)
        // 0x60 csrrw stvec,x8    0x64 addi x6,x0,256
        // 0x68 csrrw mtvec,x6    0x6C mret
        dut_a.sram0.memory[0]  = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_a.sram0.memory[1]  = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_a.sram0.memory[2]  = {enc_addi(5'd7,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_a.sram0.memory[3]  = {enc_csrrw(`CSR_MIDELEG,5'd7), enc_slli(5'd7,5'd7,6'd9)};
        dut_a.sram0.memory[4]  = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SIE,5'd7)};
        dut_a.sram0.memory[5]  = {enc_ori(5'd3,5'd3,2), enc_slli(5'd3,5'd3,6'd11)};
        dut_a.sram0.memory[6]  = {enc_addi(5'd4,5'd0,1028), enc_csrrw(`CSR_MSTATUS,5'd3)};
        dut_a.sram0.memory[7]  = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_a.sram0.memory[8]  = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_a.sram0.memory[9]  = {enc_addi(5'd8,5'd0,1028), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_a.sram0.memory[10] = {enc_addi(5'd11,5'd0,4), enc_slli(5'd8,5'd8,6'd20)};
        dut_a.sram0.memory[11] = {enc_or(5'd8,5'd8,5'd11), enc_slli(5'd11,5'd11,6'd12)};
        dut_a.sram0.memory[12] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_STVEC,5'd8)};
        dut_a.sram0.memory[13] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        // M-mode fallback @PA 0x100 (word 32) -- must NEVER be reached.
        dut_a.sram0.memory[32] = {EBREAK_INSN, enc_addi(5'd31,5'd0,1)};
        // Page table (shared L2/L1, L0 entries 3 and 4 -- VA 0x40403000
        // (mepc) and 0x40404000 (stvec) are a FULL page apart, so they
        // land on genuinely DIFFERENT L0 entries, both in word 1536):
        // L2@0x1000 entry1 -> L1@0x2000 (PPN=2).
        dut_a.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        // L1@0x2000 entry2 -> L0@0x3000 (PPN=3).
        dut_a.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        // L0@0x3000 entry3 (VA 0x40403000, mepc) -> leaf PPN=4 (PA
        // 0x4000), entry4 (VA 0x40404000, stvec) -> leaf PPN=5 (PA
        // 0x5000). Both RWXAD=1,U=0.
        dut_a.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_a.sram0.memory[1536 + 4] = 64'h0000_0000_0000_14CF;
        // mepc code @PA 0x4000 (word 2048): an infinite JAL-to-self loop --
        // the SEI must interrupt it; if it never does, the timeout fires.
        dut_a.sram0.memory[2048] = {NOP_INSN, encode_j(0, 5'd0, `OPC_JAL)};
        // stvec (S-mode handler) code @PA 0x5000 (word 2560):
        //   addi x6,x0,90         csrrs x20,scause
        //   nop                   jal x0,0 (spin forever -- NOT ebreak: an
        //     EBREAK here would be a real synchronous trap this core
        //     re-takes forever (medeleg[3]=0, so it retraps to mtvec every
        //     time), corrupting scause/mepc for anyone that checks them
        //     after even one more re-entry; a self-loop settles cleanly)
        dut_a.sram0.memory[2560] = {enc_addi(5'd6,5'd0,90), enc_csrrs(`CSR_SCAUSE,5'd20)};
        dut_a.sram0.memory[2561] = {NOP_INSN, encode_j(0, 5'd0, `OPC_JAL)};

        /* ==== Test B program ==== */
        // Same satp/page-table setup as A (reusing the SAME mapped VA
        // 0x40403000 as the S-mode entry point -- MTI doesn't need
        // mideleg/sie at all, since an M-owned, non-delegated interrupt is
        // unconditionally enabled once running below M-mode, per
        // mti_enabled's own current_priv!=PRIV_M term). x9 is loaded (in
        // M-mode, before mret -- GPRs persist across the privilege change)
        // with the UNMAPPED VA 0x40404000. The S-mode entry point's own
        // code is just `jalr x0,x9,0`: once that commits, pc<=0x40404000
        // takes effect, and i_mtip_b is asserted on that SAME commit edge
        // (see dut_b's own trigger, declared alongside its instantiation)
        // -- so mti_pending&&mti_enabled becomes true exactly as the VERY
        // NEXT cycle's S_FETCH begins for that unmapped VA, and
        // interrupt_taken fires before any walk of 0x40404000 is ever
        // attempted. mtvec = PA 0x100.
        // 0x00 addi x1,x0,8      0x04 slli x1,x1,60
        // 0x08 addi x2,x0,1      0x0C or   x1,x1,x2
        // 0x10 csrrw satp,x1     0x14 addi x7,x0,128        (mie.MTIE = bit7 --
        //                                                    mti_pending itself needs
        //                                                    mie&mip, separate from
        //                                                    mti_enabled's own privilege
        //                                                    gating; omitting this means
        //                                                    the interrupt is never even
        //                                                    pending, real bug this test's
        //                                                    own first draft had)
        // 0x18 csrrw mie,x7      0x1C addi x3,x0,1
        // 0x20 slli x3,x3,11     0x24 csrrw mstatus,x3      (mstatus.MPP=S)
        // 0x28 addi x4,x0,0x404  0x2C slli x4,x4,20
        // 0x30 addi x5,x0,3      0x34 slli x5,x5,12
        // 0x38 or x4,x4,x5       0x3C csrrw mepc,x4          (mepc = VA 0x40403000, mapped)
        // 0x40 addi x9,x0,0x404  0x44 slli x9,x9,20
        // 0x48 addi x10,x0,4     0x4C slli x10,x10,12
        // 0x50 or x9,x9,x10      0x54 addi x6,x0,256         (x9 = VA 0x40404000, unmapped)
        // 0x58 csrrw mtvec,x6    0x5C mret
        dut_b.sram0.memory[0]  = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_b.sram0.memory[1]  = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_b.sram0.memory[2]  = {enc_addi(5'd7,5'd0,128), enc_csrrw(`CSR_SATP,5'd1)};
        dut_b.sram0.memory[3]  = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_MIE,5'd7)};
        dut_b.sram0.memory[4]  = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_b.sram0.memory[5]  = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_b.sram0.memory[6]  = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_b.sram0.memory[7]  = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_b.sram0.memory[8]  = {enc_slli(5'd9,5'd9,6'd20), enc_addi(5'd9,5'd0,1028)};
        dut_b.sram0.memory[9]  = {enc_slli(5'd10,5'd10,6'd12), enc_addi(5'd10,5'd0,4)};
        dut_b.sram0.memory[10] = {enc_addi(5'd6,5'd0,256), enc_or(5'd9,5'd9,5'd10)};
        dut_b.sram0.memory[11] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        // S-mode entry @VA 0x40403000 (PA 0x4000, word 2048): the JALR to
        // the unmapped VA held in x9. A poison instruction right after it
        // (never legitimately reached -- the JALR never returns) would
        // catch any regression that somehow falls through instead of
        // redirecting.
        dut_b.sram0.memory[2048] = {enc_addi(5'd2,5'd0,111), enc_jalr(5'd0,5'd9,0)};
        // M-mode handler @PA 0x100 (word 32): the real target.
        //   addi x6,x0,90       csrrs x20,mcause
        //   csrrs x21,mepc      jal x0,0 (spin -- see test A's own handler
        //                                 comment for why not ebreak)
        dut_b.sram0.memory[32] = {enc_addi(5'd6,5'd0,90), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_b.sram0.memory[33] = {NOP_INSN, enc_csrrs(`CSR_MEPC,5'd21)};
        dut_b.sram0.memory[34] = {NOP_INSN, encode_j(0, 5'd0, `OPC_JAL)};
        // Page table: L2@0x1000 entry1 -> L1@0x2000 (PPN=2);
        // L1@0x2000 entry2 -> L0@0x3000 (PPN=3). L0@0x3000 entry4 (VA
        // 0x40404000) is left ZERO -- V=0, genuinely unmapped.
        dut_b.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801;
        dut_b.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        // L0@0x3000 entry3 (VA 0x40403000, mepc/S-mode entry) -> leaf
        // PPN=4 (PA 0x4000, the JALR code above), RWXAD=1,U=0.
        dut_b.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;

        /* ==== Test C program ==== */
        // Bare mode (satp untouched, MODE=0 by reset default), U-mode,
        // MTI pending from before reset. PMP: pmpaddr0 = 0x2000>>2 (TOR
        // upper bound), pmpcfg0 = TOR,R=0 (denies [0,0x2000)) -- so a JALR
        // into 0x2000 itself is a fresh, PMP-*permitted* region start, but
        // JALR to 0x1000 IS denied. Actually: TOR denies [prev,addr) when
        // R/W/X=0 for that entry -- construct pmpaddr0=0x400 (=0x1000>>2),
        // pmpcfg0 entry0 = TOR,R=W=X=0 (denies [0,0x1000)); pmpaddr1 =
        // 0x800 (=0x2000>>2), pmpcfg1 = TOR,R=W=X=1 (permits [0x1000,
        // 0x2000)) -- everything above 0x2000 falls through unmatched,
        // which for U-mode with no matching entry is DENY (PMP default).
        // JALR target = 0x2100 (unmatched -> denied for U-mode).
        // 0x00 addi x7,x0,128     0x04 csrrw mie,x7          (mie.MTIE)
        // 0x08 addi x1,x0,0x400   0x0C csrrw pmpaddr0,x1
        // 0x10 addi x2,x0,0x800   0x14 csrrw pmpaddr1,x2
        // 0x18 addi x3,x0,9       0x1C slli x3,x3,8          (cfg1: TOR,R=1 at byte 8)
        // 0x20 or   x3,x3,x3      0x24 addi x1,x0,8          (cfg0: TOR,R=W=X=0 = 0x08)
        // 0x28 or   x3,x3,x1      0x2C csrrw pmpcfg0,x3
        // 0x30 addi x4,x0,0x21    0x34 slli x4,x4,8           (x4 = 0x2100)
        // 0x38 addi x5,x0,0x18    0x3C csrrw mepc,x4          (mepc = 0x2100)
        // 0x40 addi x9,x5,0       0x44 addi x6,x0,256
        // 0x48 csrrw mtvec,x6     0x4C addi x3,x0,0x180       (mstatus: MPP=U(00), MIE=1(1<<3))
        // 0x50 csrrw mstatus,x3   0x54 mret
        // (mepc is set DIRECTLY to the PMP-denied address 0x2100 -- mret
        // lands there straight away, no separate JALR needed: the
        // interrupt, already pending+enabled the instant U-mode is
        // entered, fires from `interrupt_taken` before any fetch of 0x2100
        // is ever attempted, per the fix. A defensive poison instruction
        // is placed there anyway in case the fix regresses.)
        dut_c.sram0.memory[0]  = {enc_csrrw(`CSR_MIE,5'd7), enc_addi(5'd7,5'd0,128)};
        dut_c.sram0.memory[1]  = {enc_csrrw(`CSR_PMPADDR0,5'd1), enc_addi(5'd1,5'd0,'h400)};
        // x2 = x1<<1 = 0x800 -- NOT enc_addi(x2,0,'h800): 0x800 (2048)
        // exceeds ADDI's +-2047 signed-12-bit immediate range and would
        // sign-extend to a huge negative pmpaddr1 (a real bug this test
        // itself first shipped with, caught by simulation).
        dut_c.sram0.memory[2]  = {enc_csrrw(`CSR_PMPADDR1,5'd2), enc_slli(5'd2,5'd1,6'd1)};
        dut_c.sram0.memory[3]  = {enc_slli(5'd3,5'd3,6'd8), enc_addi(5'd3,5'd0,9)};
        dut_c.sram0.memory[4]  = {enc_addi(5'd1,5'd0,8), enc_or(5'd3,5'd3,5'd3)};
        dut_c.sram0.memory[5]  = {enc_csrrw(`CSR_PMPCFG0,5'd3), enc_or(5'd3,5'd3,5'd1)};
        dut_c.sram0.memory[6]  = {enc_slli(5'd4,5'd4,6'd8), enc_addi(5'd4,5'd0,'h21)};
        dut_c.sram0.memory[7]  = {enc_csrrw(`CSR_MEPC,5'd4), enc_addi(5'd5,5'd0,'h18)};
        dut_c.sram0.memory[8]  = {enc_addi(5'd6,5'd0,256), enc_addi(5'd9,5'd5,0)};
        dut_c.sram0.memory[9]  = {enc_addi(5'd3,5'd0,'h180), enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_c.sram0.memory[10] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MSTATUS,5'd3)};
        // Defensive: real code at the denied address 0x2100 (word 1056) --
        // if the bug regresses, this poisons x22 (a register untouched by
        // anything else in this program, so it's unambiguously 0 unless
        // this instruction genuinely ran) so the check below catches it
        // even if mcause/mepc happen to look plausible.
        dut_c.sram0.memory[1056] = {NOP_INSN, enc_addi(5'd22,5'd0,222)};
        // M-mode handler @PA 0x100 (word 32). Spin forever, not ebreak --
        // see test A's own handler comment for why.
        dut_c.sram0.memory[32] = {enc_addi(5'd6,5'd0,90), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_c.sram0.memory[33] = {NOP_INSN, enc_csrrs(`CSR_MEPC,5'd21)};
        dut_c.sram0.memory[34] = {NOP_INSN, encode_j(0, 5'd0, `OPC_JAL)};

        /* ==== Test D1/D2 program (identical) ==== */
        // Same satp/page-table setup as A (no interrupts at all): drop to
        // S-mode, then loop at the mapped VA forever (x1 counts
        // iterations, visible proof of "which loop instance is running").
        // 0x00-0x30: identical to A's own satp setup (no mideleg/sie).
        // 0x00 addi x1,x0,8      0x04 slli x1,x1,60
        // 0x08 addi x2,x0,1      0x0C or   x1,x1,x2
        // 0x10 csrrw satp,x1     0x14 addi x3,x0,1
        // 0x18 slli x3,x3,11     0x1C csrrw mstatus,x3      (MPP=S)
        // 0x20 addi x4,x0,0x404  0x24 slli x4,x4,20
        // 0x28 addi x5,x0,3      0x2C slli x5,x5,12
        // 0x30 or x4,x4,x5       0x34 csrrw mepc,x4          (mepc = VA 0x40403000)
        // 0x38 addi x6,x0,256    0x3C csrrw mtvec,x6
        // 0x40 mret
        dut_d1.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_d1.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_d1.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_d1.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_d1.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_d1.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_d1.sram0.memory[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        dut_d1.sram0.memory[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_d1.sram0.memory[8] = {NOP_INSN, `INSTR_HEX_MRET};
        // M-mode fallback @PA 0x100 -- must never be reached.
        dut_d1.sram0.memory[32] = {EBREAK_INSN, enc_addi(5'd31,5'd0,1)};
        dut_d1.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801;
        dut_d1.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        // Leaf @VA 0x40403000 (word 1536 entry 3) -> PA 0x4000, U=0 (S-mode
        // code can NEVER execute from a U=1 page -- unlike data access,
        // there is no SUM-equivalent permission for fetch, per
        // ptw_u_violation's own !ptw_is_mem term): addi x1,x1,1 ; jal x0,-4
        // (loop).
        dut_d1.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_d1.sram0.memory[2048] = {encode_j(-4, 5'd0, `OPC_JAL), enc_addi(5'd1,5'd1,1)};
        // D1's NEW target VA 0x40404000 (word 1536 entry 4, a genuinely
        // separate, independently-walked leaf) -> PA 0x6000, U=0:
        // addi x2,x0,555 ; jal x0,0 (spin -- not ebreak, see test A's own
        // handler comment). dpc is poked to this VA while halted.
        dut_d1.sram0.memory[1536 + 4] = 64'h0000_0000_0000_18CF;
        dut_d1.sram0.memory[3072] = {encode_j(0, 5'd0, `OPC_JAL), enc_addi(5'd2,5'd0,555)};

        dut_d2.sram0.memory[0] = dut_d1.sram0.memory[0];
        dut_d2.sram0.memory[1] = dut_d1.sram0.memory[1];
        dut_d2.sram0.memory[2] = dut_d1.sram0.memory[2];
        dut_d2.sram0.memory[3] = dut_d1.sram0.memory[3];
        dut_d2.sram0.memory[4] = dut_d1.sram0.memory[4];
        dut_d2.sram0.memory[5] = dut_d1.sram0.memory[5];
        dut_d2.sram0.memory[6] = dut_d1.sram0.memory[6];
        dut_d2.sram0.memory[7] = dut_d1.sram0.memory[7];
        dut_d2.sram0.memory[8] = dut_d1.sram0.memory[8];
        dut_d2.sram0.memory[32] = dut_d1.sram0.memory[32];
        dut_d2.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801;
        dut_d2.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_d2.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_d2.sram0.memory[2048] = {encode_j(-4, 5'd0, `OPC_JAL), enc_addi(5'd1,5'd1,1)};
        // D2's remap target: a SEPARATE PA (0x7000, PPN=7), same VA
        // (0x40403000) -- the SAME leaf PTE (word 1536 entry 3) gets
        // overwritten in place while halted, plus the TLB force-cleared
        // (no SFENCE.VMA can execute while parked in S_DEBUG_HALTED).
        // addi x2,x0,777 ; jal x0,0 (spin -- not ebreak, see test A's own
        // handler comment).
        dut_d2.sram0.memory[3584] = {encode_j(0, 5'd0, `OPC_JAL), enc_addi(5'd2,5'd0,777)};

        seip_a  = 1'b0;
        // i_mtip_b: driven entirely by its own always block above (the
        // JALR's own commit), not asserted here.
        i_mtip_c = 1'b1; // pending from BEFORE reset -- already latched when mie.MTIE enables

        @(posedge clk); #1;
        rst_a = 0; rst_b = 0; rst_c = 0; rst_d1 = 0; rst_d2 = 0;

        // Test A: assert SEIP a few cycles in, well after satp/mideleg/sie
        // setup but before mret -- SEI stays pending (masked by
        // sstatus.SIE=0 in M-mode, which mret never touches) until mret
        // lands in S-mode with SIE already set directly (see word[5]'s own
        // comment above).
        repeat (20) @(posedge clk);
        seip_a = 1'b1;

        repeat (SETTLE_CYCLES) @(posedge clk);
        #1;

        check("A: handler ran (scause==SEI, x20=0x8000000000000009)",
              dut_a.core0.regfile0.gp_registers[20], 64'h8000_0000_0000_0009);
        check("A: handler marker x6==90", dut_a.core0.regfile0.gp_registers[6], 64'd90);
        check("A: M-mode fallback never ran (x31==0)", dut_a.core0.regfile0.gp_registers[31], 64'd0);
        check("A: never hit a poison/fallback trap", {63'b0, poison_trap_a}, 64'd0);

        check("B: mcause==standard MTI encoding", dut_b.core0.regfile0.gp_registers[20], 64'h8000_0000_0000_0007);
        check("B: mepc==the unmapped VA (0x40404000), not corrupted by a spurious walk fault",
              dut_b.core0.regfile0.gp_registers[21], 64'h4040_4000);
        check("B: handler marker x6==90", dut_b.core0.regfile0.gp_registers[6], 64'd90);
        check("B: never hit a poison/fallback trap", {63'b0, poison_trap_b}, 64'd0);

        check("C: mcause==standard MTI encoding", dut_c.core0.regfile0.gp_registers[20], 64'h8000_0000_0000_0007);
        check("C: mepc==the PMP-denied address (0x2100), not corrupted by a spurious fault",
              dut_c.core0.regfile0.gp_registers[21], 64'h2100);
        check("C: poisoned target never actually executed (x22==0)", dut_c.core0.regfile0.gp_registers[22], 64'd0);
        check("C: handler marker x6==90", dut_c.core0.regfile0.gp_registers[6], 64'd90);
        check("C: never hit a poison/fallback trap", {63'b0, poison_trap_c}, 64'd0);

        // ---- D1/D2: let the loop run a bit, halt, poke, resume ----
        repeat (60) @(posedge clk);

        halt_req_d1 = 1'b1;
        halt_req_d2 = 1'b1;
        fork
            wait (dut_d1.o_debug_mode === 1'b1 && dut_d2.o_debug_mode === 1'b1);
            begin
                repeat (500) @(posedge clk);
                $display("TIMEOUT: dut_d1.o_debug_mode=%0d dut_d2.o_debug_mode=%0d",
                          dut_d1.o_debug_mode, dut_d2.o_debug_mode);
                $finish;
            end
        join_any
        disable fork;
        #1;

        // D1: poke dpc to the NEW VA (backdoor register write -- same
        // convention core_debug_halt_tb.sv already establishes for dpc_q;
        // no CSR/Access-Register path is wired on this harness).
        dut_d1.core0.csr_file0.dpc_q = 64'h4040_4000;

        // D2: dpc UNCHANGED. Remap the SAME leaf PTE in place (PPN 4 -> 7)
        // and force-clear the TLB -- mirrors what a real SFENCE.VMA would
        // do, done directly since no instruction can execute while halted.
        dut_d2.sram0.memory[1536 + 3] = 64'h0000_0000_0000_1CCF;
        dut_d2.core0.tlb0_valid_q = 1'b0;
        dut_d2.core0.tlb1_valid_q = 1'b0;
        dut_d2.core0.tlb2_valid_q = 1'b0;
        dut_d2.core0.tlb3_valid_q = 1'b0;

        @(negedge clk);
        halt_req_d1 = 1'b0;
        halt_req_d2 = 1'b0;
        resume_req_d1 = 1'b1;
        resume_req_d2 = 1'b1;
        @(posedge clk); #1;
        resume_req_d1 = 1'b0;
        resume_req_d2 = 1'b0;

        repeat (RESUME_SETTLE_CYCLES) @(posedge clk);
        #1;

        check("D1: resumed fetch came from the NEW dpc (x2==555)", dut_d1.core0.regfile0.gp_registers[2], 64'd555);
        check("D1: never hit a poison/fallback trap", {63'b0, poison_trap_d1}, 64'd0);

        check("D2: resumed fetch used the NEW mapping (x2==777)", dut_d2.core0.regfile0.gp_registers[2], 64'd777);
        check("D2: never hit a poison/fallback trap", {63'b0, poison_trap_d2}, 64'd0);

        $display("");
        $display("core_sv39_irq_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_irq_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
