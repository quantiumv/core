// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: csr_file_priv_random_tb
 *
 * Randomized property test for csr_file.sv's trap-entry/MRET/SRET side
 * channel -- separate from csr_file_tb.sv (directed, hand-picked
 * sequences, 65/65 passing -- don't touch it) and from
 * csr_file_random_tb.sv (randomized, but only Zicsr-era mscratch/mcycle/
 * minstret -- doesn't drive the privilege side channel at all). Same
 * repo convention both those files already established: one file per
 * testbench concern, duplicate the small clk/rst/dut-instantiation
 * scaffold rather than share it. Instantiates csr_file directly, no
 * core involved -- same as both precedents.
 *
 * What this targets: mstatus_q's always_ff block (csr_file.sv) has FOUR
 * possible writers -- trap-entry-to-M, trap-entry-to-S, MRET, SRET, or
 * an ordinary i_csr_we write to mstatus/sstatus -- resolved by if/else-if
 * priority. mepc_q/sepc_q/mcause_q/scause_q/mtval_q/stval_q each have
 * TWO possible writers (a trap-entry targeting that half, or an ordinary
 * write to that CSR's own address). csr_file_tb.sv's checks 14-17
 * exercise this atomic-update logic with exactly 4 hand-picked sequences
 * (an M-target trap, then an S-target trap, then one MRET, then one
 * SRET, in that fixed order, with fixed operand values chosen to be
 * easy to hand-verify). That leaves the actual state space -- thousands
 * of possible orderings/interleavings of these five write sources
 * (trap-to-M, trap-to-S, MRET, SRET, ordinary write) against
 * arbitrary prior mstatus content, arbitrary i_current_priv, and
 * arbitrary CSR addresses/data -- almost entirely unexercised. This
 * file drives NUM_ITER such randomized edges and checks the real
 * mstatus_q/mepc_q/sepc_q/mcause_q/scause_q/mtval_q/stval_q against an
 * independent shadow model after every single one.
 *
 * Shadow model: seven plain testbench-local registers (shadow_mstatus
 * plus one each for mepc/sepc/mcause/scause/mtval/stval), updated every
 * iteration with rules re-derived directly from the RISC-V privileged
 * spec / from this project's own already-verified facts about mstatus
 * bit positions and trap/MRET/SRET semantics (see this session's task
 * brief, facts 9-12) -- NOT by reading csr_file.sv's own always_ff
 * bodies and transcribing them. This is the same "don't test an
 * implementation against itself" discipline csr_file_tb.sv's own header
 * already states it follows, applied here to a shadow model instead of
 * a directed test's expected-value constants. The shadow update code
 * happens to end up structurally similar to csr_file.sv's -- that's
 * expected for a byte-accurate spec transcription of a small bitfield
 * update, not evidence the two were copied from one another.
 *
 * Priority resolution -- mirrored in the shadow model as a plain
 * if/else-if chain, exactly the shape spec section 3.1.6 describes for
 * "what happens on a trap" vs "what happens on xRET" vs "what happens on
 * an ordinary CSR write": trap-entry beats MRET/SRET beats an ordinary
 * write. This chain is never actually forced to arbitrate a genuine
 * conflict here, because the stimulus below drives AT MOST ONE of
 * {trap_taken, mret_taken, sret_taken, an ordinary i_csr_we write} per
 * edge -- mirroring the real guarantee core.sv's own instruction-commit
 * logic provides (see this session's task brief, fact 11, and core.sv's
 * own Hazards reasoning): a single retiring instruction can be a trap,
 * an MRET, an SRET, or an ordinary CSR-writing instruction, never two of
 * those at once. Testing genuinely-simultaneous multi-driver assertion
 * would exercise a state core.sv can never actually produce -- not a
 * useful thing to spend iterations on.
 *
 * i_current_priv is drawn biased toward U/S ($urandom_range(0,9): 0-3
 * U, 4-7 S, 8-9 M) -- M-mode's own trap behavior is a single fixed
 * "never delegate" case (fact 11) already directly covered by
 * csr_file_tb.sv's check 14, so spending disproportionate iteration
 * budget re-covering it here has low marginal value; U/S is where
 * MPP/SPP capture and the trap_to_s split actually have room to vary.
 * M-mode is still drawn ~20% of the time, not zero, for breadth.
 *
 * When a trap iteration draws i_current_priv==M, i_trap_to_s is forced
 * to 0 rather than independently randomized -- mirroring the same
 * "don't test an impossible input" reasoning as the priority point
 * above: core.sv's medeleg-based routing (fact 11) forces trap_to_s low
 * unconditionally whenever current_priv==M, so a real M-mode trap with
 * trap_to_s=1 is a combination core.sv can never actually drive onto
 * this side channel. csr_file.sv itself does not enforce this (it just
 * honors whatever i_trap_to_s says, trusting core.sv already decided
 * correctly -- see csr_file.sv's own module header) but this testbench
 * still only drives realistic combinations, same reasoning as the
 * priority point above. For U/S traps, i_trap_to_s is a free 50/50 coin
 * flip, since either delegation outcome is realistic from those modes.
 *
 * The CSR address for an ordinary-write iteration is drawn from
 * $urandom_range(0,11), biased toward the seven addresses actually
 * checked here (~67% of write iterations hit MSTATUS/SSTATUS/MEPC/SEPC/
 * MCAUSE/SCAUSE/MTVAL/STVAL directly) but with real weight left over for
 * unrelated addresses (MIE/MTVEC/STVEC/SATP/MEDELEG/SSCRATCH/MSCRATCH),
 * a fixed unmapped probe (12'h000), and a fully-random 12-bit address --
 * the same "mostly hit the interesting addresses, keep probing the rest
 * of the space" shape csr_file_random_tb.sv already established for its
 * own address selection. The "unrelated address" and "unmapped" buckets
 * are not idle filler: every iteration re-checks all seven tracked
 * registers regardless of what happened that edge, so a write to (say)
 * mscratch that incorrectly also disturbed mstatus_q would be caught
 * immediately by that same edge's check -- this doubles as a passive
 * regression test that ordinary writes to unrelated CSRs cannot leak
 * into the trap/MRET/SRET-owned state this file exists to stress.
 *
 * quiet_on_pass=1'b1 (via testbench/check_lib.sv's shared check() task,
 * same contract csr_file_random_tb.sv/divider_random_tb.sv already use)
 * -- NUM_ITER * 7 checks would otherwise flood the log with thousands of
 * PASS lines. Every FAIL always prints in full, with that same
 * iteration's complete randomized input vector (action taken, priv,
 * trap_to_s, mret/sret, csr_we/addr/wdata, trap cause/val/pc) baked
 * into the check's own name string -- a failure is never just "check N
 * failed", it carries everything needed to reproduce it by hand.
 *
 * Seeding: same as both precedents -- no explicit $srandom call; this
 * iverilog build's bare $urandom/$urandom_range are confirmed
 * run-to-run deterministic unseeded.
 */
module csr_file_priv_random_tb;

    localparam int NUM_ITER = 2000;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [(`CSR_ADDR_SIZE - 1):0] csr_addr;
    logic [(`WORD_SIZE - 1):0]     csr_rdata;
    logic                          csr_we;
    logic [(`WORD_SIZE - 1):0]     csr_wdata;
    logic                          instr_retired;

    logic [1:0]                    current_priv;
    logic                          trap_taken;
    logic [(`WORD_SIZE - 1):0]     trap_cause;
    logic [(`WORD_SIZE - 1):0]     trap_val;
    logic [(`WORD_SIZE - 1):0]     trap_pc;
    logic                          trap_to_s;
    logic                          mret_taken;
    logic                          sret_taken;

    logic [(`WORD_SIZE - 1):0]     mtvec_w, stvec_w, mepc_w, sepc_w, medeleg_w;
    logic [1:0]                    mstatus_mpp_w;
    logic                          mstatus_spp_w;

    csr_file dut (
        .i_clk(clk),
        .i_rst(rst),
        .i_csr_addr(csr_addr),
        .o_csr_rdata(csr_rdata),
        .i_csr_we(csr_we),
        .i_csr_wdata(csr_wdata),
        .i_instr_retired(instr_retired),

        .i_current_priv(current_priv),
        .i_trap_taken(trap_taken),
        .i_trap_cause(trap_cause),
        .i_trap_val(trap_val),
        .i_trap_pc(trap_pc),
        .i_trap_to_s(trap_to_s),
        .i_mret_taken(mret_taken),
        .i_sret_taken(sret_taken),

        .o_mtvec(mtvec_w),
        .o_stvec(stvec_w),
        .o_mepc(mepc_w),
        .o_sepc(sepc_w),
        .o_medeleg(medeleg_w),
        .o_mstatus_mpp(mstatus_mpp_w),
        .o_mstatus_spp(mstatus_spp_w)
    );

    /* Local mirrors of csr_file.sv's address map -- same reasoning as
     * both precedents: drive addresses by name, not raw hex, at each
     * call site. */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MSTATUS  = 12'h300;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SSTATUS  = 12'h100;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MEPC     = 12'h341;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SEPC     = 12'h141;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MCAUSE   = 12'h342;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SCAUSE   = 12'h142;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MTVAL    = 12'h343;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_STVAL    = 12'h143;

    /* "Other real" addresses -- backed storage that is NOT any of the
     * seven registers tracked by the shadow model below. Used only for
     * breadth (see module header); never referenced by the shadow update
     * logic, since none of them can affect mstatus/mepc/sepc/mcause/
     * scause/mtval/stval. */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MIE      = 12'h304;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MTVEC    = 12'h305;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_STVEC    = 12'h105;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SATP     = 12'h180;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MEDELEG  = 12'h302;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SSCRATCH = 12'h140;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MSCRATCH = 12'h340;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_UNMAPPED = 12'h000;

    /* mstatus bit positions -- independently transcribed from the
     * RISC-V privileged spec (facts 9-12 in this session's task brief),
     * NOT read from csr_file.sv's own localparams. */
    localparam int SIE_BIT=1, MIE_BIT=3, SPIE_BIT=5, MPIE_BIT=7, SPP_BIT=8;
    localparam int MPP_LSB=11, MPP_MSB=12;
    localparam int MPRV_BIT=17, SUM_BIT=18, MXR_BIT=19, TVM_BIT=20, TW_BIT=21, TSR_BIT=22;

    localparam logic [1:0] PRIV_U = 2'b00;
    localparam logic [1:0] PRIV_S = 2'b01;
    localparam logic [1:0] PRIV_M = 2'b11;

    /*
     * Shadow model -- plain variables, not clocked flops. Updated by
     * hand in the loop below, from the spec, using the exact values
     * driven on that same edge. Reset value 0 matches every one of
     * csr_file.sv's i_rst arms for these seven registers.
     */
    logic [(`WORD_SIZE - 1):0] shadow_mstatus = `WORD_SIZE'(0);
    logic [(`WORD_SIZE - 1):0] shadow_mepc    = `WORD_SIZE'(0);
    logic [(`WORD_SIZE - 1):0] shadow_sepc    = `WORD_SIZE'(0);
    logic [(`WORD_SIZE - 1):0] shadow_mcause  = `WORD_SIZE'(0);
    logic [(`WORD_SIZE - 1):0] shadow_scause  = `WORD_SIZE'(0);
    logic [(`WORD_SIZE - 1):0] shadow_mtval   = `WORD_SIZE'(0);
    logic [(`WORD_SIZE - 1):0] shadow_stval   = `WORD_SIZE'(0);

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b1;   /* NUM_ITER * 7 checks would otherwise flood the log with thousands of PASS lines. */
    `include "check_lib.sv"

    initial begin
        /* Per-iteration randomized stimulus -- declared once, reassigned
         * unconditionally in full every iteration (same "no partial
         * carry-over between iterations" discipline csr_file_random_tb.sv
         * uses for its own addr/we/wdata/retired). */
        int unsigned action_sel, priv_sel, addr_sel, sub_sel;
        string       action_name;
        logic [1:0]  priv_v;
        logic        trap_taken_v, trap_to_s_v, mret_taken_v, sret_taken_v, csr_we_v;
        logic [(`WORD_SIZE - 1):0]     trap_cause_v, trap_val_v, trap_pc_v, wdata_v;
        logic [(`CSR_ADDR_SIZE - 1):0] addr_v;
        string       ctx;

        csr_addr = 0; csr_we = 0; csr_wdata = 0; instr_retired = 0;
        current_priv = 0; trap_taken = 0; trap_cause = 0; trap_val = 0; trap_pc = 0; trap_to_s = 0;
        mret_taken = 0; sret_taken = 0;

        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;

        for (int i = 0; i < NUM_ITER; i++) begin

            /* ---- i_current_priv: biased toward U/S, M drawn ~20% of the time. ---- */
            priv_sel = $urandom_range(0, 9);
            if (priv_sel <= 3)      priv_v = PRIV_U;
            else if (priv_sel <= 7) priv_v = PRIV_S;
            else                    priv_v = PRIV_M;

            /* ---- Action: exactly one of {trap, mret, sret, ordinary write, idle}
             * per edge -- see module header for why this mirrors core.sv's own
             * one-driver-per-edge guarantee rather than testing an impossible
             * simultaneous-multi-driver case. ---- */
            trap_taken_v = 1'b0; trap_to_s_v = 1'b0; trap_cause_v = 0; trap_val_v = 0; trap_pc_v = 0;
            mret_taken_v = 1'b0; sret_taken_v = 1'b0;
            csr_we_v = 1'b0; addr_v = 0; wdata_v = 0;

            action_sel = $urandom_range(0, 9);
            if (action_sel <= 2) begin
                /* 0,1,2 (30%): trap-entry. */
                action_name  = "trap";
                trap_taken_v = 1'b1;
                /* current_priv==M never delegates (fact 11) -- forcing
                 * trap_to_s=0 here keeps this iteration a combination
                 * core.sv could actually produce; see module header. */
                trap_to_s_v  = (priv_v == PRIV_M) ? 1'b0 : 1'($urandom_range(0, 1));
                trap_cause_v = {$urandom(), $urandom()};
                trap_val_v   = {$urandom(), $urandom()};
                trap_pc_v    = {$urandom(), $urandom()};
            end else if (action_sel <= 4) begin
                /* 3,4 (20%): MRET. */
                action_name  = "mret";
                mret_taken_v = 1'b1;
            end else if (action_sel <= 6) begin
                /* 5,6 (20%): SRET. */
                action_name  = "sret";
                sret_taken_v = 1'b1;
            end else if (action_sel <= 8) begin
                /* 7,8 (20%): ordinary CSR write, biased address (see module header). */
                action_name = "write";
                csr_we_v    = 1'b1;
                wdata_v     = {$urandom(), $urandom()};

                addr_sel = $urandom_range(0, 11);
                case (addr_sel)
                    0:  addr_v = CSR_ADDR_MSTATUS;
                    1:  addr_v = CSR_ADDR_SSTATUS;
                    2:  addr_v = CSR_ADDR_MEPC;
                    3:  addr_v = CSR_ADDR_SEPC;
                    4:  addr_v = CSR_ADDR_MCAUSE;
                    5:  addr_v = CSR_ADDR_SCAUSE;
                    6:  addr_v = CSR_ADDR_MTVAL;
                    7:  addr_v = CSR_ADDR_STVAL;
                    8, 9: begin
                        /* "Other real" address -- must not perturb any tracked register. */
                        sub_sel = $urandom_range(0, 6);
                        case (sub_sel)
                            0: addr_v = CSR_ADDR_MIE;
                            1: addr_v = CSR_ADDR_MTVEC;
                            2: addr_v = CSR_ADDR_STVEC;
                            3: addr_v = CSR_ADDR_SATP;
                            4: addr_v = CSR_ADDR_MEDELEG;
                            5: addr_v = CSR_ADDR_SSCRATCH;
                            default: addr_v = CSR_ADDR_MSCRATCH;
                        endcase
                    end
                    10: addr_v = CSR_ADDR_UNMAPPED;
                    default: addr_v = (`CSR_ADDR_SIZE)'($urandom_range(0, 4095));
                endcase
            end else begin
                /* 9 (10%): idle -- no driver asserted; every tracked register
                 * must hold exactly its prior value across this edge. */
                action_name = "idle";
            end

            /* Drive on negedge, latch on posedge -- same convention both
             * precedents use for driving DUT inputs sampled on the clock edge. */
            @(negedge clk);
            current_priv  = priv_v;
            trap_taken    = trap_taken_v;
            trap_to_s     = trap_to_s_v;
            trap_cause    = trap_cause_v;
            trap_val      = trap_val_v;
            trap_pc       = trap_pc_v;
            mret_taken    = mret_taken_v;
            sret_taken    = sret_taken_v;
            csr_we        = csr_we_v;
            csr_addr      = addr_v;
            csr_wdata     = wdata_v;
            instr_retired = 1'b0;   /* not exercised by this pillar -- minstret is out of scope. */
            @(posedge clk); #1;

            /* ---------------------------------------------------------------
             * Shadow model update -- independently re-derived rules (see
             * module header), applied with this same edge's driven values.
             * --------------------------------------------------------------- */

            /* mstatus: trap-entry beats MRET beats SRET beats an ordinary
             * mstatus/sstatus write beats "unchanged". */
            if (trap_taken_v) begin
                if (trap_to_s_v) begin
                    shadow_mstatus[SPIE_BIT] = shadow_mstatus[SIE_BIT];
                    shadow_mstatus[SIE_BIT]  = 1'b0;
                    shadow_mstatus[SPP_BIT]  = priv_v[0];
                end else begin
                    shadow_mstatus[MPIE_BIT] = shadow_mstatus[MIE_BIT];
                    shadow_mstatus[MIE_BIT]  = 1'b0;
                    shadow_mstatus[MPP_MSB:MPP_LSB] = priv_v;
                end
            end else if (mret_taken_v) begin
                /* Per spec: an mret/sret that drops privilege below M also
                 * clears MPRV. Destination priv here is the PRE-update MPP;
                 * MRET returning to M itself (MPP==2'b11) leaves MPRV alone. */
                if (shadow_mstatus[MPP_MSB:MPP_LSB] != 2'b11)
                    shadow_mstatus[MPRV_BIT] = 1'b0;
                shadow_mstatus[MIE_BIT]  = shadow_mstatus[MPIE_BIT];
                shadow_mstatus[MPIE_BIT] = 1'b1;
                shadow_mstatus[MPP_MSB:MPP_LSB] = 2'b00;
            end else if (sret_taken_v) begin
                /* SPP is 1 bit (U or S only), so SRET's destination is never
                 * M -- MPRV unconditionally clears, unlike MRET's check above. */
                shadow_mstatus[MPRV_BIT] = 1'b0;
                shadow_mstatus[SIE_BIT]  = shadow_mstatus[SPIE_BIT];
                shadow_mstatus[SPIE_BIT] = 1'b1;
                shadow_mstatus[SPP_BIT]  = 1'b0;
            end else if (csr_we_v && (addr_v == CSR_ADDR_MSTATUS)) begin
                shadow_mstatus[SIE_BIT]  = wdata_v[SIE_BIT];
                shadow_mstatus[MIE_BIT]  = wdata_v[MIE_BIT];
                shadow_mstatus[SPIE_BIT] = wdata_v[SPIE_BIT];
                shadow_mstatus[MPIE_BIT] = wdata_v[MPIE_BIT];
                shadow_mstatus[SPP_BIT]  = wdata_v[SPP_BIT];
                shadow_mstatus[MPP_MSB:MPP_LSB] = wdata_v[MPP_MSB:MPP_LSB];
                shadow_mstatus[MPRV_BIT] = wdata_v[MPRV_BIT];
                shadow_mstatus[SUM_BIT]  = wdata_v[SUM_BIT];
                shadow_mstatus[MXR_BIT]  = wdata_v[MXR_BIT];
                shadow_mstatus[TVM_BIT]  = wdata_v[TVM_BIT];
                shadow_mstatus[TW_BIT]   = wdata_v[TW_BIT];
                shadow_mstatus[TSR_BIT]  = wdata_v[TSR_BIT];
            end else if (csr_we_v && (addr_v == CSR_ADDR_SSTATUS)) begin
                shadow_mstatus[SIE_BIT]  = wdata_v[SIE_BIT];
                shadow_mstatus[SPIE_BIT] = wdata_v[SPIE_BIT];
                shadow_mstatus[SPP_BIT]  = wdata_v[SPP_BIT];
                shadow_mstatus[SUM_BIT]  = wdata_v[SUM_BIT];
                shadow_mstatus[MXR_BIT]  = wdata_v[MXR_BIT];
                /* MIE/MPIE/MPP/MPRV/TVM/TW/TSR deliberately untouched -- not visible/writable via sstatus. */
            end
            /* else: idle, MRET/SRET didn't fire, or a write to an unrelated
             * address -- shadow_mstatus holds. */

            /* mepc/sepc: trap-entry to that half, else an ordinary write to
             * that exact address (WARL-masked to bit 0, matching the RTL --
             * this core's IALIGN=16 via Zca means only bit 0 needs
             * clearing, not bit[1:0]), else unchanged. */
            if (trap_taken_v && !trap_to_s_v) shadow_mepc = trap_pc_v;
            else if (csr_we_v && (addr_v == CSR_ADDR_MEPC)) shadow_mepc = {wdata_v[(`WORD_SIZE - 1):1], 1'b0};

            if (trap_taken_v && trap_to_s_v) shadow_sepc = trap_pc_v;
            else if (csr_we_v && (addr_v == CSR_ADDR_SEPC)) shadow_sepc = {wdata_v[(`WORD_SIZE - 1):1], 1'b0};

            /* mcause/scause: same shape. */
            if (trap_taken_v && !trap_to_s_v) shadow_mcause = trap_cause_v;
            else if (csr_we_v && (addr_v == CSR_ADDR_MCAUSE)) shadow_mcause = wdata_v;

            if (trap_taken_v && trap_to_s_v) shadow_scause = trap_cause_v;
            else if (csr_we_v && (addr_v == CSR_ADDR_SCAUSE)) shadow_scause = wdata_v;

            /* mtval/stval: same shape. */
            if (trap_taken_v && !trap_to_s_v) shadow_mtval = trap_val_v;
            else if (csr_we_v && (addr_v == CSR_ADDR_MTVAL)) shadow_mtval = wdata_v;

            if (trap_taken_v && trap_to_s_v) shadow_stval = trap_val_v;
            else if (csr_we_v && (addr_v == CSR_ADDR_STVAL)) shadow_stval = wdata_v;

            /* ---------------------------------------------------------------
             * Checks -- full randomized input vector baked into every check's
             * name string, so a FAIL is self-contained and reproducible by
             * hand without cross-referencing anything else in the log.
             * --------------------------------------------------------------- */
            ctx = $sformatf(
                "iter %0d [action=%s priv=%0d trap_taken=%0d trap_to_s=%0d mret=%0d sret=%0d csr_we=%0d addr=%h wdata=%h cause=%h val=%h pc=%h]",
                i, action_name, priv_v, trap_taken_v, trap_to_s_v, mret_taken_v, sret_taken_v,
                csr_we_v, addr_v, wdata_v, trap_cause_v, trap_val_v, trap_pc_v);

            check({ctx, " mstatus_q"}, dut.mstatus_q, shadow_mstatus);
            check({ctx, " mepc_q"},    dut.mepc_q,    shadow_mepc);
            check({ctx, " sepc_q"},    dut.sepc_q,    shadow_sepc);
            check({ctx, " mcause_q"},  dut.mcause_q,  shadow_mcause);
            check({ctx, " scause_q"},  dut.scause_q,  shadow_scause);
            check({ctx, " mtval_q"},   dut.mtval_q,   shadow_mtval);
            check({ctx, " stval_q"},   dut.stval_q,   shadow_stval);
        end

        $display("");
        $display("csr_file_priv_random_tb: %0d iterations, %0d checks passed, %0d checks failed",
                  NUM_ITER, pass_count, fail_count);
        if (fail_count > 0) $display("csr_file_priv_random_tb: FAILURES PRESENT");
        $finish;
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
