// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: csr_file
 *
 * Standalone, drives csr_file directly -- no core involved. Needs a clock
 * (every flip-flop in the DUT is synchronous) and a reset (everything
 * zeros on i_rst, unlike register_file.sv's gp_registers).
 *
 * As of the U/S/M privilege-mode milestone, this also directly drives the
 * trap-entry/MRET/SRET side channel (i_trap_taken/i_mret_taken/etc.) --
 * core.sv is the only other place these ports are ever driven, so this
 * file is the sole standalone proof that csr_file.sv's own atomic-update
 * logic (mstatus_q's four writers, mepc/sepc/mcause/scause/mtval/stval's
 * two writers each) is correct, independent of whether core.sv's own
 * classification wires (is_illegal_instr, trap_to_s, etc.) are right.
 */
module csr_file_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [(`CSR_ADDR_SIZE - 1):0] csr_addr;
    logic [(`WORD_SIZE - 1):0]     csr_rdata;
    logic                          csr_we;
    logic [(`WORD_SIZE - 1):0]     csr_wdata;
    logic                          instr_retired;

    logic [1:0]                    current_priv;
    logic                          mtip;
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
    logic                          mstatus_tsr_w;

    /* Milestone 5: CSR-side CLINT/interrupt plumbing exports. mideleg_w is
     * a NEW, DISTINCT wire from medeleg_w above -- exception delegation
     * and interrupt delegation are different CSRs, not aliases. */
    logic [(`WORD_SIZE - 1):0]     mip_w, mie_w, mideleg_w;
    logic                          mstatus_mie_w, mstatus_sie_w;

    csr_file dut (
        .i_clk(clk),
        .i_rst(rst),
        .i_csr_addr(csr_addr),
        .o_csr_rdata(csr_rdata),
        .i_csr_we(csr_we),
        .i_csr_wdata(csr_wdata),
        .i_instr_retired(instr_retired),

        .i_current_priv(current_priv),
        .i_mtip(mtip),
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
        .o_mstatus_spp(mstatus_spp_w),
        .o_mstatus_tsr(mstatus_tsr_w),

        .o_mip(mip_w),
        .o_mie(mie_w),
        .o_mideleg(mideleg_w),
        .o_mstatus_mie(mstatus_mie_w),
        .o_mstatus_sie(mstatus_sie_w)
    );

    /* Local mirrors of csr_file.sv's address map -- this testbench drives
     * addresses by name, same as core.sv eventually will via imm_2, rather
     * than re-deriving them from raw hex each call site. */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MISA      = 12'h301;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MVENDORID = 12'hF11;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MARCHID   = 12'hF12;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MIMPID    = 12'hF13;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MHARTID   = 12'hF14;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MSCRATCH  = 12'h340;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MCYCLE    = 12'hB00;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MINSTRET  = 12'hB02;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_UNMAPPED  = 12'h000;

    localparam logic [(`WORD_SIZE - 1):0] MISA_VALUE = 64'h8000_0000_0000_0100;

    /* U/S/M privilege-mode milestone additions -- independently
     * transcribed from the spec (not read from csr_file.sv's own
     * internals), same "don't test against your own implementation"
     * discipline this project has used throughout. */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SSTATUS    = 12'h100;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SIE        = 12'h104;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_STVEC      = 12'h105;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SCOUNTEREN = 12'h106;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SSCRATCH   = 12'h140;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SEPC       = 12'h141;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SCAUSE     = 12'h142;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_STVAL      = 12'h143;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SIP        = 12'h144;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SATP       = 12'h180;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MSTATUS    = 12'h300;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MEDELEG    = 12'h302;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MIDELEG    = 12'h303;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MIE        = 12'h304;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MTVEC      = 12'h305;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MCOUNTEREN = 12'h306;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MEPC       = 12'h341;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MCAUSE     = 12'h342;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MTVAL      = 12'h343;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MIP        = 12'h344;

    /* mstatus bit positions, independently transcribed from the spec. */
    localparam int SIE_BIT=1, MIE_BIT=3, SPIE_BIT=5, MPIE_BIT=7, SPP_BIT=8;
    localparam int MPP_LSB=11, MPP_MSB=12;
    localparam int MPRV_BIT=17, SUM_BIT=18, MXR_BIT=19, TVM_BIT=20, TW_BIT=21, TSR_BIT=22;
    localparam logic [(`WORD_SIZE-1):0] UXL_FIXED = (`WORD_SIZE'(2) << 32);
    localparam logic [(`WORD_SIZE-1):0] SXL_FIXED = (`WORD_SIZE'(2) << 34);
    /* Every real mstatus bit set to 1 -- used both as an all-1s write
     * (to prove ONLY these bits stick) and to build expected values. */
    localparam logic [(`WORD_SIZE-1):0] MSTATUS_ALL_REAL_BITS =
        (`WORD_SIZE'(1) << SIE_BIT) | (`WORD_SIZE'(1) << MIE_BIT) |
        (`WORD_SIZE'(1) << SPIE_BIT) | (`WORD_SIZE'(1) << MPIE_BIT) |
        (`WORD_SIZE'(1) << SPP_BIT) |
        (`WORD_SIZE'(3) << MPP_LSB) |
        (`WORD_SIZE'(1) << MPRV_BIT) | (`WORD_SIZE'(1) << SUM_BIT) | (`WORD_SIZE'(1) << MXR_BIT) |
        (`WORD_SIZE'(1) << TVM_BIT) | (`WORD_SIZE'(1) << TW_BIT) | (`WORD_SIZE'(1) << TSR_BIT);
    /* sstatus's own visible subset, independently transcribed. */
    localparam logic [(`WORD_SIZE-1):0] SSTATUS_VISIBLE_BITS =
        (`WORD_SIZE'(1) << SIE_BIT) | (`WORD_SIZE'(1) << SPIE_BIT) |
        (`WORD_SIZE'(1) << SPP_BIT) | (`WORD_SIZE'(1) << SUM_BIT) | (`WORD_SIZE'(1) << MXR_BIT);

    int pass_count = 0;
    int fail_count = 0;

    task automatic check(string name, logic [(`WORD_SIZE-1):0] actual, logic [(`WORD_SIZE-1):0] expected);
        if (actual === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    /* Read helper: drive the address, settle combinationally, sample. */
    task automatic read_csr(logic [(`CSR_ADDR_SIZE - 1):0] a, output logic [(`WORD_SIZE - 1):0] d);
        csr_addr = a;
        #1;
        d = csr_rdata;
    endtask

    /* Write helper: one synchronous write cycle, mirroring wb4_sram_tb.sv's
     * "drive on negedge, latch on posedge" convention for driving DUT
     * inputs that are sampled on the clock edge. */
    task automatic write_csr(logic [(`CSR_ADDR_SIZE - 1):0] a, logic [(`WORD_SIZE - 1):0] d);
        @(negedge clk);
        csr_addr = a; csr_wdata = d; csr_we = 1;
        @(posedge clk); #1;
        csr_we = 0;
    endtask

    logic [(`WORD_SIZE - 1):0] rdata;

    initial begin
        csr_addr = 0; csr_we = 0; csr_wdata = 0; instr_retired = 0;
        current_priv = 0; mtip = 0; trap_taken = 0; trap_cause = 0; trap_val = 0; trap_pc = 0; trap_to_s = 0;
        mret_taken = 0; sret_taken = 0;

        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;

        /*
         * 1. Post-reset: misa's exact fixed bit pattern, and every other
         * fixed/backed CSR reading 0.
         */
        read_csr(CSR_ADDR_MISA, rdata);
        check("post-reset misa exact bit pattern", rdata, MISA_VALUE);
        read_csr(CSR_ADDR_MVENDORID, rdata);
        check("post-reset mvendorid reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MARCHID, rdata);
        check("post-reset marchid reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MIMPID, rdata);
        check("post-reset mimpid reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MHARTID, rdata);
        check("post-reset mhartid reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MSCRATCH, rdata);
        check("post-reset mscratch reads 0", rdata, `WORD_SIZE'(0));

        /*
         * 2. mscratch: plain read/write round trip.
         */
        write_csr(CSR_ADDR_MSCRATCH, 64'hCAFEBABE_12345678);
        read_csr(CSR_ADDR_MSCRATCH, rdata);
        check("mscratch write/read-back round trip", rdata, 64'hCAFEBABE_12345678);

        /*
         * 3. Write-to-misa (all-ones) is silently ignored -- still reads
         * the exact fixed pattern afterward.
         */
        write_csr(CSR_ADDR_MISA, 64'hFFFFFFFF_FFFFFFFF);
        read_csr(CSR_ADDR_MISA, rdata);
        check("write to misa is ignored", rdata, MISA_VALUE);

        /*
         * 4. mcycle free-runs +1 every clock edge from reset, with
         * i_csr_we/i_instr_retired both held low throughout -- proves it
         * advances unconditionally, not gated on either signal.
         */
        begin
            logic [(`WORD_SIZE - 1):0] mcycle_before, mcycle_after;
            csr_we = 0; instr_retired = 0;
            read_csr(CSR_ADDR_MCYCLE, mcycle_before);
            @(posedge clk); #1;
            read_csr(CSR_ADDR_MCYCLE, mcycle_after);
            check("mcycle free-runs +1 across one edge", mcycle_after, mcycle_before + 64'd1);
            @(posedge clk); #1;
            read_csr(CSR_ADDR_MCYCLE, mcycle_after);
            check("mcycle free-runs +1 across a second edge", mcycle_after, mcycle_before + 64'd2);
        end

        /*
         * 5. minstret stays 0 across several clock edges while
         * i_instr_retired=0, then reads back exactly K after K
         * retire-pulses -- the direct free-running-vs-gated contrast with
         * mcycle above.
         */
        instr_retired = 0;
        repeat (3) begin
            @(posedge clk); #1;
        end
        read_csr(CSR_ADDR_MINSTRET, rdata);
        check("minstret stays 0 with i_instr_retired low", rdata, `WORD_SIZE'(0));

        begin
            int unsigned k;
            k = 5;
            for (int unsigned i = 0; i < k; i++) begin
                @(negedge clk);
                instr_retired = 1;
                @(posedge clk); #1;
                instr_retired = 0;
            end
            read_csr(CSR_ADDR_MINSTRET, rdata);
            check("minstret reads back exactly K after K retire-pulses", rdata, `WORD_SIZE'(k));
        end

        /*
         * 6. Unmapped address reads 0.
         */
        read_csr(CSR_ADDR_UNMAPPED, rdata);
        check("unmapped address reads 0", rdata, `WORD_SIZE'(0));

        /*
         * 7. A write to an unmapped address doesn't corrupt mscratch --
         * regression, mirrors register_file_tb.sv's write-enable-polarity
         * regression pattern: write a known value to mscratch, then
         * attempt an unmapped write, then confirm mscratch is untouched.
         */
        write_csr(CSR_ADDR_MSCRATCH, 64'hA5A5A5A5_5A5A5A5A);
        write_csr(CSR_ADDR_UNMAPPED, 64'hFFFFFFFF_FFFFFFFF);
        read_csr(CSR_ADDR_MSCRATCH, rdata);
        check("write to unmapped address doesn't corrupt mscratch", rdata, 64'hA5A5A5A5_5A5A5A5A);

        /*
         * 8. Direct write attempts at mcycle/minstret are ignored -- both
         * counters have no write-reacting arm, so a write must not alter
         * their free-running/retirement-driven progression.
         */
        begin
            logic [(`WORD_SIZE - 1):0] mcycle_before, mcycle_after, minstret_after;
            read_csr(CSR_ADDR_MCYCLE, mcycle_before);
            write_csr(CSR_ADDR_MCYCLE, 64'hDEADDEAD_DEADDEAD);
            read_csr(CSR_ADDR_MCYCLE, mcycle_after);
            // write_csr consumed one clock edge, so mcycle free-runs by
            // exactly +1 regardless -- the check is that it is NOT the
            // written value, and matches the expected free-run count.
            check("direct write to mcycle is ignored (still free-running)", mcycle_after, mcycle_before + 64'd1);

            read_csr(CSR_ADDR_MINSTRET, rdata);
            write_csr(CSR_ADDR_MINSTRET, 64'hDEADDEAD_DEADDEAD);
            read_csr(CSR_ADDR_MINSTRET, minstret_after);
            check("direct write to minstret is ignored (i_instr_retired stayed low)", minstret_after, rdata);
        end

        /*
         * ===================================================================
         * U/S/M privilege-mode milestone additions, below.
         * ===================================================================
         */

        /*
         * 9. Post-reset: every new backed CSR reads its correct reset
         * value. mstatus/sstatus read the UXL/SXL WARL-fixed pattern even
         * though their underlying storage is all-zero (the fixed bits are
         * OR'd in on every read, not stored) -- everything else reads a
         * plain 0.
         */
        read_csr(CSR_ADDR_MSTATUS, rdata);
        check("post-reset mstatus reads UXL/SXL fixed pattern only", rdata, UXL_FIXED | SXL_FIXED);
        read_csr(CSR_ADDR_SSTATUS, rdata);
        check("post-reset sstatus reads UXL fixed pattern only", rdata, UXL_FIXED);
        read_csr(CSR_ADDR_MEDELEG, rdata);  check("post-reset medeleg reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MIDELEG, rdata);  check("post-reset mideleg reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MIE, rdata);      check("post-reset mie reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MTVEC, rdata);    check("post-reset mtvec reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MEPC, rdata);     check("post-reset mepc reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MCAUSE, rdata);   check("post-reset mcause reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MTVAL, rdata);    check("post-reset mtval reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MIP, rdata);      check("post-reset mip reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_STVEC, rdata);    check("post-reset stvec reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_SEPC, rdata);     check("post-reset sepc reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_SCAUSE, rdata);   check("post-reset scause reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_STVAL, rdata);    check("post-reset stval reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_SIE, rdata);      check("post-reset sie reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_SIP, rdata);      check("post-reset sip reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_SATP, rdata);     check("post-reset satp reads 0", rdata, `WORD_SIZE'(0));

        /*
         * 10. mstatus bit-by-bit round trip: write ALL-ONES (the most
         * disambiguating input possible -- exercises every bit at once)
         * and confirm ONLY the real bits stick, everything else (SD/FS/
         * XS/VS/unimplemented fields) reads back 0 regardless of what was
         * written, plus the WARL-fixed UXL/SXL pattern.
         */
        write_csr(CSR_ADDR_MSTATUS, {`WORD_SIZE{1'b1}});
        read_csr(CSR_ADDR_MSTATUS, rdata);
        check("mstatus all-1s write: only real bits stick, plus WARL-fixed UXL/SXL",
              rdata, MSTATUS_ALL_REAL_BITS | UXL_FIXED | SXL_FIXED);

        /*
         * 11. sstatus's masked view, both directions:
         *  (a) mstatus's MIE/MPP (NOT in sstatus's visible set) must not
         *      leak through a sstatus read, even though they're currently
         *      set from check 10 above.
         *  (b) writing sstatus must not disturb mstatus's MIE/MPP/MPRV/
         *      TVM/TW/TSR (the bits sstatus can't see).
         */
        read_csr(CSR_ADDR_SSTATUS, rdata);
        check("sstatus view: MIE/MPP don't leak through, only the visible subset shows",
              rdata, SSTATUS_VISIBLE_BITS | UXL_FIXED);

        write_csr(CSR_ADDR_SSTATUS, `WORD_SIZE'(0));  // clear every sstatus-visible bit
        read_csr(CSR_ADDR_MSTATUS, rdata);
        check("sstatus write to 0: mstatus's MIE/MPP/MPRV/TVM/TW/TSR survive untouched",
              rdata,
              (MSTATUS_ALL_REAL_BITS & ~SSTATUS_VISIBLE_BITS) | UXL_FIXED | SXL_FIXED);
        read_csr(CSR_ADDR_SSTATUS, rdata);
        check("sstatus write to 0: sstatus's own visible bits actually cleared",
              rdata, UXL_FIXED);

        /* Restore mstatus to all-1s for the sie/sip tests below, so SIE/MIE are known-1. */
        write_csr(CSR_ADDR_MSTATUS, {`WORD_SIZE{1'b1}});

        /*
         * 12. sie/sip masked-by-mideleg round trip: delegate only bits 1
         * and 5 (arbitrary, disambiguating choice), write mie directly to
         * all-1s, then write sie to all-0s -- only the delegated bits
         * (1,5) should clear; everything else stays 1.
         */
        write_csr(CSR_ADDR_MIDELEG, (`WORD_SIZE'(1) << 1) | (`WORD_SIZE'(1) << 5));
        check("o_mideleg output matches mideleg_q after write",
              mideleg_w, (`WORD_SIZE'(1) << 1) | (`WORD_SIZE'(1) << 5));
        write_csr(CSR_ADDR_MIE, {`WORD_SIZE{1'b1}});
        check("o_mie output matches mie_q after write", mie_w, {`WORD_SIZE{1'b1}});
        read_csr(CSR_ADDR_SIE, rdata);
        check("sie read: masked by mideleg, shows only delegated bits", rdata,
              {`WORD_SIZE{1'b1}} & ((`WORD_SIZE'(1) << 1) | (`WORD_SIZE'(1) << 5)));
        write_csr(CSR_ADDR_SIE, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MIE, rdata);
        check("sie write to 0: only mideleg-delegated bits (1,5) cleared in mie, rest stay 1",
              rdata, {`WORD_SIZE{1'b1}} & ~((`WORD_SIZE'(1) << 1) | (`WORD_SIZE'(1) << 5)));
        check("o_mie output matches mie_q after sie-masked write", mie_w,
              {`WORD_SIZE{1'b1}} & ~((`WORD_SIZE'(1) << 1) | (`WORD_SIZE'(1) << 5)));
        /* sip: identical shape, spot-checked once (mip/mie share the same masked-write logic).
         * Bit 7 (MTIP) is excluded from the expected pattern: Milestone 5's write-masking
         * means bit 7 never sticks from a software write to mip/sip regardless of value
         * written, and mip_effective's read-mux override means it reads back i_mtip's
         * current value (still 0 at this point in the sequence) rather than 1 or X. */
        write_csr(CSR_ADDR_MIP, {`WORD_SIZE{1'b1}});
        write_csr(CSR_ADDR_SIP, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MIP, rdata);
        check("sip write to 0: only mideleg-delegated bits cleared in mip, rest stay 1 (bit 7 excluded -- see comment)",
              rdata, ({`WORD_SIZE{1'b1}} & ~((`WORD_SIZE'(1) << 1) | (`WORD_SIZE'(1) << 5))) & ~(`WORD_SIZE'(1) << 7));
        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(0));  // clean up for later sections

        /*
         * 13. Plain read/write registers -- one round trip each, distinct
         * per-register values so a copy-paste mistake (writing the wrong
         * register) would produce a visibly wrong readback.
         */
        write_csr(CSR_ADDR_STVEC, 64'h0000_0000_1000_2004);  read_csr(CSR_ADDR_STVEC, rdata);
        check("stvec round trip", rdata, 64'h0000_0000_1000_2004);
        write_csr(CSR_ADDR_MTVEC, 64'h0000_0000_2000_3008);  read_csr(CSR_ADDR_MTVEC, rdata);
        check("mtvec round trip", rdata, 64'h0000_0000_2000_3008);
        write_csr(CSR_ADDR_MCOUNTEREN, 64'h0000_0000_0000_0007);  read_csr(CSR_ADDR_MCOUNTEREN, rdata);
        check("mcounteren round trip", rdata, 64'h0000_0000_0000_0007);
        write_csr(CSR_ADDR_SCOUNTEREN, 64'h0000_0000_0000_0003);  read_csr(CSR_ADDR_SCOUNTEREN, rdata);
        check("scounteren round trip", rdata, 64'h0000_0000_0000_0003);
        write_csr(CSR_ADDR_SSCRATCH, 64'hFEED_FACE_BEEF_CAFE);  read_csr(CSR_ADDR_SSCRATCH, rdata);
        check("sscratch round trip", rdata, 64'hFEED_FACE_BEEF_CAFE);
        write_csr(CSR_ADDR_SATP, 64'h8000_0000_0004_0000);  read_csr(CSR_ADDR_SATP, rdata);
        check("satp round trip (real storage, no PTW consumer yet)", rdata, 64'h8000_0000_0004_0000);
        write_csr(CSR_ADDR_MEDELEG, 64'h0000_0000_0000_B3FF);  read_csr(CSR_ADDR_MEDELEG, rdata);
        check("medeleg round trip", rdata, 64'h0000_0000_0000_B3FF);

        /*
         * 14. Trap-entry, M-target: drive the side channel directly (no
         * core.sv involved), confirm mepc_q/mcause_q/mtval_q AND
         * mstatus's MPIE/MIE/MPP all update atomically on the same edge
         * -- and that the S-side fields (SIE/SPIE/SPP) are left alone.
         *
         * Setup: mstatus's SIE=1/MIE=1 beforehand (via ordinary write),
         * so pushing MIE->MPIE and clearing MIE is a real, observable
         * 1->0 transition, not a 0->0 coincidence.
         */
        write_csr(CSR_ADDR_MSTATUS, (`WORD_SIZE'(1) << SIE_BIT) | (`WORD_SIZE'(1) << MIE_BIT));
        @(negedge clk);
        current_priv = 2'b01;  // S -- the mode the trap is taken FROM
        trap_taken = 1'b1; trap_to_s = 1'b0;  // targets M
        trap_cause = `WORD_SIZE'(2);          // illegal-instruction
        trap_val   = 64'hDEAD_BEEF_0000_0001;
        trap_pc    = 64'h0000_0000_0000_1000;
        @(posedge clk); #1;
        trap_taken = 1'b0;

        read_csr(CSR_ADDR_MEPC, rdata);   check("M-target trap: mepc captured", rdata, 64'h0000_0000_0000_1000);
        read_csr(CSR_ADDR_MCAUSE, rdata); check("M-target trap: mcause captured", rdata, `WORD_SIZE'(2));
        read_csr(CSR_ADDR_MTVAL, rdata);  check("M-target trap: mtval captured", rdata, 64'hDEAD_BEEF_0000_0001);
        read_csr(CSR_ADDR_MSTATUS, rdata);
        check("M-target trap: mstatus MPIE<-old MIE(1), MIE<-0, MPP<-S(01), SIE/SPIE/SPP untouched",
              rdata,
              (`WORD_SIZE'(1) << MPIE_BIT)       // MPIE <- old MIE (1)
            | (`WORD_SIZE'(1) << SIE_BIT)         // SIE: untouched, still 1 from setup
            | (`WORD_SIZE'(1) << MPP_LSB)         // MPP <- 2'b01 (S)
            | UXL_FIXED | SXL_FIXED);
        check("M-target trap: o_mepc output matches", mepc_w, 64'h0000_0000_0000_1000);
        check("M-target trap: o_mstatus_mpp output matches", {62'b0, mstatus_mpp_w}, `WORD_SIZE'(2'b01));
        check("M-target trap: o_mstatus_mie output tracks MIE<-0", mstatus_mie_w, 1'b0);
        check("M-target trap: o_mstatus_sie output tracks SIE untouched (1)", mstatus_sie_w, 1'b1);

        /*
         * 15. Trap-entry, S-target: same shape, different values, and
         * critically confirms the M-side fields captured in check 14
         * above (mepc/mcause/mtval/MPIE/MIE/MPP) are UNCHANGED by an
         * S-target trap -- proves the two target groups are genuinely
         * independent, not just "happens to also work".
         */
        /* A CSR write to mstatus fully replaces every writable bit (per
         * spec -- not a merge/OR), so MPIE/MPP from check 14 must be
         * explicitly carried forward here alongside setting SIE=1, or
         * this setup write would itself wipe them before the S-target
         * trap even runs, corrupting the very thing this check means to
         * prove untouched. */
        write_csr(CSR_ADDR_MSTATUS,
                  (`WORD_SIZE'(1) << SIE_BIT) | (`WORD_SIZE'(1) << MPIE_BIT) | (`WORD_SIZE'(1) << MPP_LSB));
        @(negedge clk);
        current_priv = 2'b00;  // U -- the mode the trap is taken FROM
        trap_taken = 1'b1; trap_to_s = 1'b1;  // targets S
        trap_cause = `WORD_SIZE'(8);          // ECALL from U
        trap_val   = `WORD_SIZE'(0);
        trap_pc    = 64'h0000_0000_0000_2000;
        @(posedge clk); #1;
        trap_taken = 1'b0;

        read_csr(CSR_ADDR_SEPC, rdata);   check("S-target trap: sepc captured", rdata, 64'h0000_0000_0000_2000);
        read_csr(CSR_ADDR_SCAUSE, rdata); check("S-target trap: scause captured", rdata, `WORD_SIZE'(8));
        read_csr(CSR_ADDR_STVAL, rdata);  check("S-target trap: stval captured", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MSTATUS, rdata);
        check("S-target trap: mstatus SPIE<-old SIE(1), SIE<-0, SPP<-U(0), M-side fields from check 14 untouched",
              rdata,
              (`WORD_SIZE'(1) << SPIE_BIT)   // SPIE <- old SIE (1)
            | (`WORD_SIZE'(1) << MPIE_BIT)   // still set from check 14 -- M-target trap's own field
            | (`WORD_SIZE'(1) << MPP_LSB)    // still MPP=01(S) from check 14
            | UXL_FIXED | SXL_FIXED);
        check("S-target trap: o_sepc output matches", sepc_w, 64'h0000_0000_0000_2000);
        check("S-target trap: o_mstatus_spp output matches (SPP<-U, i.e. 0)", `WORD_SIZE'(mstatus_spp_w), `WORD_SIZE'(0));
        /* M-side fields genuinely untouched by the S-target trap -- direct regression. */
        read_csr(CSR_ADDR_MEPC, rdata);   check("S-target trap didn't disturb mepc from check 14", rdata, 64'h0000_0000_0000_1000);
        read_csr(CSR_ADDR_MCAUSE, rdata); check("S-target trap didn't disturb mcause from check 14", rdata, `WORD_SIZE'(2));

        /*
         * 16. MRET: restores MIE from MPIE, sets MPIE=1, resets MPP to U
         * (2'b00) per spec. Current mstatus state entering this check:
         * MIE=0/MPIE=1/MPP=01(S) from check 14 (S-target trap didn't
         * touch these), SIE=0/SPIE=1/SPP=0 from check 15.
         */
        @(negedge clk);
        mret_taken = 1'b1;
        @(posedge clk); #1;
        mret_taken = 1'b0;
        read_csr(CSR_ADDR_MSTATUS, rdata);
        check("mret: MIE<-old MPIE(1), MPIE<-1, MPP<-U(00), S-side fields untouched",
              rdata,
              (`WORD_SIZE'(1) << MIE_BIT)    // MIE <- old MPIE (1)
            | (`WORD_SIZE'(1) << MPIE_BIT)   // MPIE <- 1 per spec
            | (`WORD_SIZE'(1) << SPIE_BIT)   // untouched, still 1 from check 15
            | UXL_FIXED | SXL_FIXED);        // MPP is now 00 -- contributes nothing
        check("mret: o_mstatus_mpp reads back U (00)", `WORD_SIZE'(mstatus_mpp_w), `WORD_SIZE'(0));

        /*
         * 17. SRET: restores SIE from SPIE, sets SPIE=1, resets SPP to U
         * per spec. Entering this check: SIE=0/SPIE=1/SPP=0 (check 15,
         * untouched by mret above).
         */
        @(negedge clk);
        sret_taken = 1'b1;
        @(posedge clk); #1;
        sret_taken = 1'b0;
        read_csr(CSR_ADDR_MSTATUS, rdata);
        check("sret: SIE<-old SPIE(1), SPIE<-1, SPP<-U(0), M-side fields untouched",
              rdata,
              (`WORD_SIZE'(1) << SIE_BIT)    // SIE <- old SPIE (1)
            | (`WORD_SIZE'(1) << SPIE_BIT)   // SPIE <- 1 per spec
            | (`WORD_SIZE'(1) << MIE_BIT)    // untouched, still 1 from check 16 (mret)
            | (`WORD_SIZE'(1) << MPIE_BIT)   // untouched, still 1 from check 16 (mret)
            | UXL_FIXED | SXL_FIXED);
        check("sret: o_mstatus_spp reads back U (0)", `WORD_SIZE'(mstatus_spp_w), `WORD_SIZE'(0));

        /*
         * ===================================================================
         * Milestone 5 additions: mip.MTIP (bit 7) is a live combinational
         * function of i_mtip (mip_effective in csr_file.sv), not stored
         * state like every other mip bit. These checks confirm (a) mip/sip
         * reads track i_mtip with NO clock edge involved at all -- the
         * signal is flipped directly and re-read immediately, never via
         * write_csr/an explicit @(posedge clk) -- including the sip-view
         * case (only visible once mideleg delegates bit 7), and (b) a
         * direct software write of all-1s to mip does not make bit 7
         * stick on any read path. Section 20 below uses a narrow
         * dut.mip_q hierarchical peek -- an exception to this file's
         * black-box discipline everywhere else, taken because (b) alone
         * cannot distinguish real write-arm masking from mip_effective's
         * read-side override hiding an unmasked mip_q regardless; see
         * section 20's own comment.
         * ===================================================================
         */

        /*
         * 18. mip/sip bit 7 tracks i_mtip live, with no clock edge.
         * Known starting state first: mideleg=0 (bit 7 not delegated to
         * S) and mip's storage cleared, so only i_mtip drives bit 7 from
         * here.
         */
        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(0));
        write_csr(CSR_ADDR_MIP, `WORD_SIZE'(0));

        mtip = 0;
        read_csr(CSR_ADDR_MIP, rdata);
        check("mip bit 7 reads 0 with i_mtip=0", `WORD_SIZE'(rdata[7]), `WORD_SIZE'(0));

        mtip = 1;  // direct signal change -- no write_csr, no clock edge
        read_csr(CSR_ADDR_MIP, rdata);
        check("mip bit 7 reads 1 immediately when i_mtip=1, no clock edge involved",
              `WORD_SIZE'(rdata[7]), `WORD_SIZE'(1));
        check("o_mip control-plane output live-tracks i_mtip the same as the CSR_ADDR_MIP read",
              `WORD_SIZE'(mip_w[7]), `WORD_SIZE'(1));

        mtip = 0;
        read_csr(CSR_ADDR_MIP, rdata);
        check("mip bit 7 drops back to 0 immediately when i_mtip drops, no clock edge involved",
              `WORD_SIZE'(rdata[7]), `WORD_SIZE'(0));

        /* sip view: with mideleg bit 7 still 0, sip must NOT show bit 7
         * even though i_mtip=1 -- the delegation mask, not i_mtip alone,
         * gates sip's visibility of MTIP. */
        mtip = 1;
        read_csr(CSR_ADDR_SIP, rdata);
        check("sip bit 7 stays 0 when mideleg bit 7 is 0, even though i_mtip=1",
              `WORD_SIZE'(rdata[7]), `WORD_SIZE'(0));

        /* Delegate bit 7 to S via mideleg -- sip's view must now show it,
         * still with no clock edge since i_mtip last changed. */
        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(1) << 7);
        read_csr(CSR_ADDR_SIP, rdata);
        check("sip bit 7 shows through once mideleg delegates it, i_mtip=1",
              `WORD_SIZE'(rdata[7]), `WORD_SIZE'(1));

        mtip = 0;  // live change again, still no clock edge
        read_csr(CSR_ADDR_SIP, rdata);
        check("sip bit 7 drops to 0 live when i_mtip drops, mideleg still delegating",
              `WORD_SIZE'(rdata[7]), `WORD_SIZE'(0));

        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(0));  // clean up

        /*
         * 19. A direct software write of all-1s to mip reads back bit 7 as
         * i_mtip's current value (0), not 1. NOTE: this alone does NOT
         * distinguish "the write-arm mask reached mip_q's storage" from
         * "mip_effective's read-mux override hides bit 7 regardless of
         * what's in storage" -- mip_effective unconditionally splices
         * i_mtip into bit 7 on every read path (CSR_ADDR_MIP, CSR_ADDR_SIP,
         * and o_mip alike), so mip_q[7] is structurally unobservable
         * through any of them whether or not the write-arm mask exists.
         * The two checks below are still worth keeping as a live-behavior
         * regression guard, just not read as write-mask proof.
         */
        mtip = 0;
        write_csr(CSR_ADDR_MIP, {`WORD_SIZE{1'b1}});
        read_csr(CSR_ADDR_MIP, rdata);
        check("mip all-1s software write: bit 7 reads back as i_mtip (0), not 1",
              `WORD_SIZE'(rdata[7]), `WORD_SIZE'(0));
        check("o_mip control-plane output agrees: bit 7 reads back as i_mtip (0), not 1",
              `WORD_SIZE'(mip_w[7]), `WORD_SIZE'(0));

        /*
         * 20. The write-arm masking itself (mip_q <= ... & ~64'h80, both
         * the direct-mip-write arm and the sip-derived-write arm) has NO
         * black-box-observable effect per the note above, so it can only
         * be verified by inspecting mip_q's own storage directly -- a
         * deliberate, narrow exception to this file's black-box discipline
         * everywhere else, taken because code review alone already missed
         * that this specific arm was untested by every check above it.
         */
        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(0));
        write_csr(CSR_ADDR_MIP, `WORD_SIZE'(0));
        write_csr(CSR_ADDR_MIP, {`WORD_SIZE{1'b1}});
        check("direct mip write-arm masks bit 7 out of mip_q storage itself",
              dut.mip_q[7], 1'b0);

        write_csr(CSR_ADDR_MIP, `WORD_SIZE'(0));
        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(1) << 7);
        write_csr(CSR_ADDR_SIP, {`WORD_SIZE{1'b1}});
        check("sip-derived write-arm masks bit 7 out of mip_q storage itself",
              dut.mip_q[7], 1'b0);
        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(0));  // clean up

        $display("");
        $display("csr_file_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("csr_file_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
