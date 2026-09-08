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
    logic                          meip, seip;  // PMP+PLIC plan Milestone 3
    logic                          trap_taken;
    logic [(`WORD_SIZE - 1):0]     trap_cause;
    logic [(`WORD_SIZE - 1):0]     trap_val;
    logic [(`WORD_SIZE - 1):0]     trap_pc;
    logic                          trap_to_s;
    logic                          mret_taken;
    logic                          sret_taken;

    /* Milestone 3: Debug-mode CSR entry side channel. */
    logic                          debug_entry;
    logic [2:0]                    debug_cause;

    logic [(`WORD_SIZE - 1):0]     mtvec_w, stvec_w, mepc_w, sepc_w, medeleg_w;
    logic [1:0]                    mstatus_mpp_w;
    logic                          mstatus_spp_w;
    logic                          mstatus_tsr_w;

    /* Milestone 5: CSR-side CLINT/interrupt plumbing exports. mideleg_w is
     * a NEW, DISTINCT wire from medeleg_w above -- exception delegation
     * and interrupt delegation are different CSRs, not aliases. */
    logic [(`WORD_SIZE - 1):0]     mip_w, mie_w, mideleg_w;
    logic                          mstatus_mie_w, mstatus_sie_w;

    /* Milestone 3: Debug CSR control-plane exports. */
    logic [(`WORD_SIZE - 1):0]     dcsr_w, dpc_w;

    /* PMP (Milestone 1 of the PMP+PLIC staged plan): control-plane exports. */
    logic [(`WORD_SIZE - 1):0]     pmpcfg0_w, pmpaddr0_w, pmpaddr1_w, pmpaddr2_w, pmpaddr3_w;
    logic                          mstatus_mprv_w;

    /* Sv39 (Milestone 1 of the Sv39 staged plan): control-plane exports. */
    logic [(`WORD_SIZE - 1):0]     satp_w;
    logic                          mstatus_sum_w, mstatus_mxr_w, mstatus_tvm_w;

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
        .i_meip(meip),
        .i_seip(seip),
        .i_trap_taken(trap_taken),
        .i_trap_cause(trap_cause),
        .i_trap_val(trap_val),
        .i_trap_pc(trap_pc),
        .i_trap_to_s(trap_to_s),
        .i_mret_taken(mret_taken),
        .i_sret_taken(sret_taken),

        .i_debug_entry(debug_entry),
        .i_debug_cause(debug_cause),

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
        .o_mstatus_sie(mstatus_sie_w),

        .o_dcsr(dcsr_w),
        .o_dpc(dpc_w),

        .o_pmpcfg0(pmpcfg0_w),
        .o_pmpaddr0(pmpaddr0_w),
        .o_pmpaddr1(pmpaddr1_w),
        .o_pmpaddr2(pmpaddr2_w),
        .o_pmpaddr3(pmpaddr3_w),
        .o_mstatus_mprv(mstatus_mprv_w),

        .o_satp(satp_w),
        .o_mstatus_sum(mstatus_sum_w),
        .o_mstatus_mxr(mstatus_mxr_w),
        .o_mstatus_tvm(mstatus_tvm_w)
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

    /* Milestone 3: Debug-mode CSR addresses, independently transcribed. */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_DCSR      = 12'h7B0;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_DPC       = 12'h7B1;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_DSCRATCH0 = 12'h7B2;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_DSCRATCH1 = 12'h7B3;
    localparam int DCSR_PRV_LSB=0, DCSR_PRV_MSB=1, DCSR_CAUSE_LSB=6, DCSR_CAUSE_MSB=8;
    localparam int DCSR_EBREAKM_BIT=15, DCSR_STEPIE_BIT=11;
    localparam logic [(`WORD_SIZE-1):0] DCSR_XDEBUGVER_FIXED = (`WORD_SIZE'(4) << 28);

    /* Milestone 9: Trigger Module CSR addresses, independently transcribed. */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_TSELECT = 12'h7A0;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_TDATA1  = 12'h7A1;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_TDATA2  = 12'h7A2;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_TDATA3  = 12'h7A3;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_TINFO   = 12'h7A4;
    localparam logic [(`WORD_SIZE-1):0] TINFO_EXPECTED = 64'h0000_0000_0100_0041;

    /* PMP (Milestone 1 of the PMP+PLIC staged plan): addresses and field
     * layout independently transcribed from riscv-isa-manual's own PMP
     * chapter (see design/csr_file.sv's own header comment for the exact
     * citations), not read from csr_file.sv's internals. */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_PMPCFG0  = 12'h3A0;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_PMPADDR0 = 12'h3B0;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_PMPADDR1 = 12'h3B1;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_PMPADDR2 = 12'h3B2;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_PMPADDR3 = 12'h3B3;
    localparam logic [(`WORD_SIZE-1):0] PMPADDR_RESET_ALL_MATCH = 64'h003F_FFFF_FFFF_FFFF;

    // Builds a pmpcfg byte from named fields (the value a debugger would write).
    function automatic logic [7:0] pmp_cfg_byte(
        input logic l, input logic [1:0] a, input logic x, input logic w, input logic r
    );
        return {l, 2'b11, a, x, w, r};  // reserved bits[6:5] deliberately set to 11 in every
                                         // write this file issues, so every check also proves
                                         // they're forced back to 0 on readback -- not just
                                         // coincidentally 0 because nothing ever wrote them.
    endfunction

    // The real hardware's own post-write value: reserved bits forced 0,
    // W collapses to 0 whenever R=0 -- independently re-derived here,
    // not copied from csr_file.sv's own always_ff, matching this file's
    // own "don't test against your own implementation" discipline.
    function automatic logic [7:0] pmp_cfg_expected(
        input logic l, input logic [1:0] a, input logic x, input logic w, input logic r
    );
        return {l, 2'b00, a, x, (w & r), r};
    endfunction

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
        current_priv = 0; mtip = 0; meip = 0; seip = 0; trap_taken = 0; trap_cause = 0; trap_val = 0; trap_pc = 0; trap_to_s = 0;
        mret_taken = 0; sret_taken = 0;
        debug_entry = 0; debug_cause = 0;

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
         * Bits 7/9/11 (MTIP/SEIP/MEIP) are excluded from the expected pattern:
         * write-masking means these bits never stick from a software write to
         * mip/sip regardless of value written, and mip_effective's read-mux
         * override means each reads back its own external i_mtip/i_seip/i_meip
         * current value (all still 0 at this point in the sequence) rather
         * than 1 or X. */
        write_csr(CSR_ADDR_MIP, {`WORD_SIZE{1'b1}});
        write_csr(CSR_ADDR_SIP, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MIP, rdata);
        check("sip write to 0: only mideleg-delegated bits cleared in mip, rest stay 1 (bits 7/9/11 excluded -- see comment)",
              rdata, ({`WORD_SIZE{1'b1}} & ~((`WORD_SIZE'(1) << 1) | (`WORD_SIZE'(1) << 5)))
                     & ~((`WORD_SIZE'(1) << 7) | (`WORD_SIZE'(1) << 9) | (`WORD_SIZE'(1) << 11)));
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
        // Bits 9/11 (SEIP/MEIP, PMP+PLIC plan Milestone 3) share the SAME
        // single ~64'hA80 mask expression as bit 7 above -- checked here
        // too, not just assumed, since a bug narrowing that mask (e.g.
        // forgetting one bit) would be invisible to every black-box mip/
        // sip read (mip_effective's read-side override hides mip_q's raw
        // storage on every read path regardless of what's actually
        // masked), making this hierarchical peek the ONLY place such a
        // bug could ever be caught.
        check("direct mip write-arm ALSO masks bit 9 (SEIP) out of mip_q storage",
              dut.mip_q[9], 1'b0);
        check("direct mip write-arm ALSO masks bit 11 (MEIP) out of mip_q storage",
              dut.mip_q[11], 1'b0);

        write_csr(CSR_ADDR_MIP, `WORD_SIZE'(0));
        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(1) << 7);
        write_csr(CSR_ADDR_SIP, {`WORD_SIZE{1'b1}});
        check("sip-derived write-arm masks bit 7 out of mip_q storage itself",
              dut.mip_q[7], 1'b0);
        check("sip-derived write-arm ALSO masks bit 9 (SEIP) out of mip_q storage",
              dut.mip_q[9], 1'b0);
        check("sip-derived write-arm ALSO masks bit 11 (MEIP) out of mip_q storage",
              dut.mip_q[11], 1'b0);
        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(0));  // clean up

        /*
         * 21. Debug-mode CSR entry (Milestone 3): drive the side channel
         * directly (no core.sv involved, i_debug_entry/i_debug_cause are
         * unconnected from core.sv's own instantiation this milestone --
         * this file is the sole standalone proof this logic is correct
         * at all). Confirms dcsr's cause/prv fields update atomically on
         * entry while every other software-set field (ebreakm/stepie
         * here, standing in for the whole "everything else" class)
         * persists untouched -- and that dpc captures i_trap_pc, same
         * reuse-not-a-new-port precedent mepc/sepc already established
         * for trap-entry.
         */
        write_csr(CSR_ADDR_DCSR, (`WORD_SIZE'(1) << DCSR_EBREAKM_BIT) | (`WORD_SIZE'(1) << DCSR_STEPIE_BIT));
        read_csr(CSR_ADDR_DCSR, rdata);
        check("dcsr pre-entry: ebreakm/stepie stick, xdebugver reads 4, cause/prv still 0",
              rdata,
              (`WORD_SIZE'(1) << DCSR_EBREAKM_BIT) | (`WORD_SIZE'(1) << DCSR_STEPIE_BIT) | DCSR_XDEBUGVER_FIXED);

        @(negedge clk);
        current_priv = 2'b01;  // S -- the mode debug entry is taken FROM
        debug_entry = 1'b1; debug_cause = 3'd1;  // 1 = ebreak, per spec
        trap_pc = 64'h0000_0000_0000_2000;
        @(posedge clk); #1;
        debug_entry = 1'b0;

        read_csr(CSR_ADDR_DCSR, rdata);
        check("dcsr post-entry: cause<-1, prv<-S(01), ebreakm/stepie/xdebugver untouched",
              rdata,
              (`WORD_SIZE'(1) << DCSR_EBREAKM_BIT) | (`WORD_SIZE'(1) << DCSR_STEPIE_BIT) | DCSR_XDEBUGVER_FIXED
              | (`WORD_SIZE'(1) << DCSR_CAUSE_LSB) | (`WORD_SIZE'(2'b01) << DCSR_PRV_LSB));
        check("o_dcsr output agrees with the CSR readback", dcsr_w, rdata);

        read_csr(CSR_ADDR_DPC, rdata);
        check("dpc captured i_trap_pc on debug entry", rdata, 64'h0000_0000_0000_2000);
        check("o_dpc output agrees with the CSR readback", dpc_w, rdata);

        /*
         * A second entry, with DIFFERENT cause/prv values, distinguishes
         * a correct overwrite from an accidental accumulate/OR bug in
         * the hardware-entry arm -- the first entry above went 0->1
         * for both fields, which an OR-accumulate bug can't be told
         * apart from a plain assign. Picked so overwrite and OR-
         * accumulate produce DIFFERENT results in both fields: cause
         * 3'd1 (001) then 3'd2 (010) -- OR gives 011(3), assign gives
         * 010(2); prv 2'b01 (S) then 2'b00 (U) -- OR leaves it stuck at
         * 01(S), assign correctly drops to 00(U).
         */
        @(negedge clk);
        current_priv = 2'b00;  // U
        debug_entry = 1'b1; debug_cause = 3'd2;
        trap_pc = 64'h0000_0000_0000_3000;
        @(posedge clk); #1;
        debug_entry = 1'b0;

        read_csr(CSR_ADDR_DCSR, rdata);
        check("dcsr second entry: cause freshly overwritten to 2 (not OR-accumulated to 3)",
              rdata[DCSR_CAUSE_MSB:DCSR_CAUSE_LSB], 3'd2);
        check("dcsr second entry: prv freshly overwritten to U(00) (not OR-stuck at S(01))",
              {62'b0, rdata[DCSR_PRV_MSB:DCSR_PRV_LSB]}, 64'd0);
        check("dcsr second entry: ebreakm still set", {63'b0, rdata[DCSR_EBREAKM_BIT]}, 64'd1);
        check("dcsr second entry: stepie still set", {63'b0, rdata[DCSR_STEPIE_BIT]}, 64'd1);
        check("dcsr second entry: xdebugver still reads 4",
              rdata & (`WORD_SIZE'(4'hF) << 28), DCSR_XDEBUGVER_FIXED);
        read_csr(CSR_ADDR_DPC, rdata);
        check("dpc re-captured i_trap_pc on the second entry too", rdata, 64'h0000_0000_0000_3000);

        /*
         * Simultaneous i_debug_entry and a same-cycle software write to
         * DCSR: the if/else-if priority chain in csr_file.sv means
         * debug_entry must win outright, not merge with the write.
         * Driven manually (not via write_csr(), which runs its own
         * separate negedge/posedge cycle) so both land on the exact
         * same clock edge.
         */
        @(negedge clk);
        current_priv = 2'b01;  // S
        debug_entry = 1'b1; debug_cause = 3'd5;
        trap_pc = 64'h0000_0000_0000_4000;
        csr_addr = CSR_ADDR_DCSR; csr_wdata = {`WORD_SIZE{1'b1}}; csr_we = 1'b1;
        @(posedge clk); #1;
        debug_entry = 1'b0; csr_we = 1'b0;

        read_csr(CSR_ADDR_DCSR, rdata);
        check("simultaneous i_debug_entry + software write: debug_entry wins outright (cause<-5)",
              rdata[DCSR_CAUSE_MSB:DCSR_CAUSE_LSB], 3'd5);
        check("simultaneous i_debug_entry + software write: debug_entry wins outright (prv<-S(01))",
              {62'b0, rdata[DCSR_PRV_MSB:DCSR_PRV_LSB]}, 64'd1);

        /* xdebugver is WARL-fixed: an all-1s software write must not stick. */
        write_csr(CSR_ADDR_DCSR, {`WORD_SIZE{1'b1}});
        read_csr(CSR_ADDR_DCSR, rdata);
        check("dcsr xdebugver field ignores an all-1s software write, still reads 4",
              rdata & (`WORD_SIZE'(4'hF) << 28), DCSR_XDEBUGVER_FIXED);
        check("dcsr bit 27 (just below xdebugver) keeps the all-1s write -- mask isn't too wide",
              {63'b0, dut.dcsr_q[27]}, 64'd1);
        check("dcsr bit 32 (just above xdebugver) keeps the all-1s write -- mask isn't too wide",
              {63'b0, dut.dcsr_q[32]}, 64'd1);

        /* dpc is WARL like mepc/sepc: bit 0 always reads 0. */
        write_csr(CSR_ADDR_DPC, 64'h0000_0000_0000_1001);
        read_csr(CSR_ADDR_DPC, rdata);
        check("dpc write is bit-0 masked (WARL), same as mepc/sepc", rdata, 64'h0000_0000_0000_1000);

        /* dscratch0/dscratch1: plain full read/write round trip. */
        write_csr(CSR_ADDR_DSCRATCH0, 64'hCAFE_F00D_0000_0001);
        read_csr(CSR_ADDR_DSCRATCH0, rdata);
        check("dscratch0 read/write round trip", rdata, 64'hCAFE_F00D_0000_0001);
        write_csr(CSR_ADDR_DSCRATCH1, 64'hCAFE_F00D_0000_0002);
        read_csr(CSR_ADDR_DSCRATCH1, rdata);
        check("dscratch1 read/write round trip", rdata, 64'hCAFE_F00D_0000_0002);
        read_csr(CSR_ADDR_DSCRATCH0, rdata);
        check("dscratch0 unaffected by dscratch1's write", rdata, 64'hCAFE_F00D_0000_0001);

        /* Milestone 9: Trigger Module CSR checks. */

        /* tinfo: read-only, unconditional. */
        read_csr(CSR_ADDR_TINFO, rdata);
        check("tinfo reads version=1/info=0x0041 unconditionally", rdata, TINFO_EXPECTED);

        /* tselect: WARL across exactly 2 legal slots (bit-0-only storage). */
        write_csr(CSR_ADDR_TSELECT, 64'd7);
        read_csr(CSR_ADDR_TSELECT, rdata);
        check("tselect write 7 reads back 1 (bit-0-only storage)", rdata, 64'd1);
        write_csr(CSR_ADDR_TSELECT, 64'd2);
        read_csr(CSR_ADDR_TSELECT, rdata);
        check("tselect write 2 reads back 0 (bit-0-only storage)", rdata, 64'd0);

        /* tdata1 WARL spot-checks, slot 0. */
        write_csr(CSR_ADDR_TSELECT, 64'd0);
        write_csr(CSR_ADDR_TDATA1, (`WORD_SIZE'(5) << 7));  // match=5
        read_csr(CSR_ADDR_TDATA1, rdata);
        check("tdata1 match field is WARL-hardwired 0 regardless of what's written", rdata[10:7], 4'd0);

        write_csr(CSR_ADDR_TDATA1, (`WORD_SIZE'(1) << 18));  // size bit set
        read_csr(CSR_ADDR_TDATA1, rdata);
        check("tdata1 size field is WARL-hardwired 0", rdata[18:16], 3'd0);

        write_csr(CSR_ADDR_TDATA1, (`WORD_SIZE'(1) << 11));  // chain
        read_csr(CSR_ADDR_TDATA1, rdata);
        check("tdata1 chain bit is WARL-hardwired 0", rdata[11], 1'd0);

        write_csr(CSR_ADDR_TDATA1, (`WORD_SIZE'(1) << 21));  // select
        read_csr(CSR_ADDR_TDATA1, rdata);
        check("tdata1 select bit is WARL-hardwired 0", rdata[21], 1'd0);

        write_csr(CSR_ADDR_TDATA1, `WORD_SIZE'(3));  // store|load
        read_csr(CSR_ADDR_TDATA1, rdata);
        check("tdata1 store/load bits are WARL-hardwired 0", rdata[1:0], 2'd0);

        write_csr(CSR_ADDR_TDATA1, (`WORD_SIZE'(3) << 12));  // action=3
        read_csr(CSR_ADDR_TDATA1, rdata);
        check("tdata1 action=3 clamps to 1 (WARL)", rdata[15:12], 4'd1);

        write_csr(CSR_ADDR_TDATA1, `WORD_SIZE'(0));  // action=0
        read_csr(CSR_ADDR_TDATA1, rdata);
        check("tdata1 action=0 stays 0 (not clamped)", rdata[15:12], 4'd0);

        write_csr(CSR_ADDR_TDATA1, {`WORD_SIZE{1'b1}});  // all-1s write
        read_csr(CSR_ADDR_TDATA1, rdata);
        check("tdata1 type field always reads 6 regardless of what's written", rdata[63:60], 4'd6);

        /* tdata1/tdata2 per-slot independence. */
        write_csr(CSR_ADDR_TSELECT, 64'd0);
        write_csr(CSR_ADDR_TDATA1, (`WORD_SIZE'(1) << 12) | (`WORD_SIZE'(1) << 2));  // action=1, execute=1
        write_csr(CSR_ADDR_TDATA2, 64'h0000_0000_0000_1000);
        write_csr(CSR_ADDR_TSELECT, 64'd1);
        write_csr(CSR_ADDR_TDATA1, (`WORD_SIZE'(1) << 6));  // m=1, action=0 (deliberately different)
        write_csr(CSR_ADDR_TDATA2, 64'h0000_0000_0000_2000);
        write_csr(CSR_ADDR_TSELECT, 64'd0);
        read_csr(CSR_ADDR_TDATA1, rdata);
        check("tdata1 slot 0 undisturbed by slot 1's own write -- action", rdata[15:12], 4'd1);
        read_csr(CSR_ADDR_TDATA2, rdata);
        check("tdata2 slot 0 undisturbed by slot 1's own write -- address", rdata, 64'h0000_0000_0000_1000);
        write_csr(CSR_ADDR_TSELECT, 64'd1);
        read_csr(CSR_ADDR_TDATA1, rdata);
        check("tdata1 slot 1 holds its own distinct value -- m bit", rdata[6], 1'd1);
        read_csr(CSR_ADDR_TDATA2, rdata);
        check("tdata2 slot 1 holds its own distinct address", rdata, 64'h0000_0000_0000_2000);

        /* tdata3: real stub, no storage. */
        write_csr(CSR_ADDR_TDATA3, {`WORD_SIZE{1'b1}});
        read_csr(CSR_ADDR_TDATA3, rdata);
        check("tdata3 reads 0 unconditionally (real stub, no storage this round)", rdata, `WORD_SIZE'(0));

        /* ----------------------------------------------------------- *
         * PMP CSRs (Milestone 1 of the PMP+PLIC staged plan).
         * ----------------------------------------------------------- */

        // 1. Reset readback: region 0 permissive (L=0,A=NAPOT,X=W=R=1,
        //    addr=all-1s -- "match everything representable"), regions
        //    1-3 fully inert (A=OFF, addr=0). See the plan's own
        //    cross-cutting decision on why the reset default must be
        //    permissive, not deny-by-default.
        read_csr(CSR_ADDR_PMPCFG0, rdata);
        check("PMP reset: region0 byte == permissive (L=0,A=NAPOT,X=W=R=1)",
            rdata[7:0], pmp_cfg_expected(1'b0, 2'b11, 1'b1, 1'b1, 1'b1));
        check("PMP reset: regions 1-3 bytes == 0 (A=OFF)", rdata[31:8], 24'h0);
        check("PMP reset: bytes 4-7 (unimplemented regions) == 0", rdata[63:32], 32'h0);
        read_csr(CSR_ADDR_PMPADDR0, rdata);
        check("PMP reset: pmpaddr0 == all-1s in bits[53:0]", rdata, PMPADDR_RESET_ALL_MATCH);
        read_csr(CSR_ADDR_PMPADDR1, rdata);
        check("PMP reset: pmpaddr1 == 0", rdata, 64'd0);
        read_csr(CSR_ADDR_PMPADDR2, rdata);
        check("PMP reset: pmpaddr2 == 0", rdata, 64'd0);
        read_csr(CSR_ADDR_PMPADDR3, rdata);
        check("PMP reset: pmpaddr3 == 0", rdata, 64'd0);

        // 2. Plain WARL round trip, all 4 regions written independently
        //    in ONE pmpcfg0 write -- proves per-region byte-slicing is
        //    correct and every region exercises a different A encoding.
        //    Every byte deliberately sets reserved bits[6:5]=11 (see
        //    pmp_cfg_byte's own comment) and R=W=1 (no collapse) so this
        //    test isolates JUST the reserved-bit-masking behavior, not
        //    the R/W collapse rule (tested separately, step 3).
        write_csr(CSR_ADDR_PMPCFG0, {
            pmp_cfg_byte(1'b1, 2'b00, 1'b0, 1'b1, 1'b1),   // region3: L=1,A=OFF,X=0,W=1,R=1
            pmp_cfg_byte(1'b0, 2'b11, 1'b1, 1'b1, 1'b1),   // region2: L=0,A=NAPOT,X=1,W=1,R=1
            pmp_cfg_byte(1'b0, 2'b10, 1'b0, 1'b1, 1'b1),   // region1: L=0,A=NA4,X=0,W=1,R=1
            pmp_cfg_byte(1'b0, 2'b01, 1'b1, 1'b1, 1'b1)    // region0: L=0,A=TOR,X=1,W=1,R=1
        });
        read_csr(CSR_ADDR_PMPCFG0, rdata);
        check("PMP WARL round trip: region0 byte (TOR, reserved bits masked)",
            rdata[7:0],   pmp_cfg_expected(1'b0, 2'b01, 1'b1, 1'b1, 1'b1));
        check("PMP WARL round trip: region1 byte (NA4, reserved bits masked)",
            rdata[15:8],  pmp_cfg_expected(1'b0, 2'b10, 1'b0, 1'b1, 1'b1));
        check("PMP WARL round trip: region2 byte (NAPOT, reserved bits masked)",
            rdata[23:16], pmp_cfg_expected(1'b0, 2'b11, 1'b1, 1'b1, 1'b1));
        check("PMP WARL round trip: region3 byte (OFF, L set, reserved bits masked)",
            rdata[31:24], pmp_cfg_expected(1'b1, 2'b00, 1'b0, 1'b1, 1'b1));

        // 3. R=0,W=1 WARL collapse (norm:pmp_rwx_warl): isolated on
        //    region1 (currently unlocked), preserving every other byte
        //    from step 2's own write.
        read_csr(CSR_ADDR_PMPCFG0, rdata);
        write_csr(CSR_ADDR_PMPCFG0, {rdata[63:16], pmp_cfg_byte(1'b0, 2'b10, 1'b0, 1'b1, 1'b0), rdata[7:0]});
        read_csr(CSR_ADDR_PMPCFG0, rdata);
        check("PMP R=0,W=1 collapses to W=0 (reserved RWX combination)",
            rdata[15:8], pmp_cfg_expected(1'b0, 2'b10, 1'b0, 1'b1, 1'b0));

        // 4. Lock persistence: region3 is ALREADY locked from step 2
        //    (L=1). Attempt to rewrite region3 AND region2 (unlocked) in
        //    the SAME write -- region3 must hold its step-2 value
        //    exactly; region2 in that same write must still update.
        begin
            logic [7:0] region3_before_attempt;
            read_csr(CSR_ADDR_PMPCFG0, rdata);
            region3_before_attempt = rdata[31:24];
            write_csr(CSR_ADDR_PMPCFG0, {
                pmp_cfg_byte(1'b1, 2'b01, 1'b1, 1'b1, 1'b1),  // attempt on locked region3
                pmp_cfg_byte(1'b0, 2'b00, 1'b0, 1'b0, 1'b0),  // fresh value for unlocked region2
                rdata[15:8], rdata[7:0]                        // leave regions 0/1 untouched
            });
            read_csr(CSR_ADDR_PMPCFG0, rdata);
            check("PMP lock: locked region3 unchanged despite a same-write rewrite attempt",
                rdata[31:24], region3_before_attempt);
            check("PMP lock: unlocked region2 in that SAME write still updated",
                rdata[23:16], pmp_cfg_expected(1'b0, 2'b00, 1'b0, 1'b0, 1'b0));
        end
        begin
            logic [(`WORD_SIZE-1):0] pmpaddr3_before;
            read_csr(CSR_ADDR_PMPADDR3, pmpaddr3_before);
            write_csr(CSR_ADDR_PMPADDR3, ~pmpaddr3_before);
            read_csr(CSR_ADDR_PMPADDR3, rdata);
            check("PMP lock: locked region3's own pmpaddr3 also refuses a direct rewrite",
                rdata, pmpaddr3_before);
        end

        // 5. TOR-preceding-address lock (norm:pmp_l_bit_write_protection):
        //    a fresh DUT reset first, so region1 (used here) starts
        //    genuinely unlocked -- step 4 above already permanently
        //    locked region3, which would otherwise contaminate this
        //    specific case.
        rst = 1; @(posedge clk); #1; @(posedge clk); #1; rst = 0;
        write_csr(CSR_ADDR_PMPCFG0, {
            8'h00,
            pmp_cfg_byte(1'b1, 2'b01, 1'b0, 1'b0, 1'b0),  // region2: L=1, A=TOR -- locks pmpaddr1 too
            8'h00, 8'h00
        });
        // pmpaddr1 is ALREADY locked the instant the write above lands
        // (region2's own L=1/A=TOR takes effect on that same edge) --
        // capture whatever it currently holds (its own reset value, 0,
        // since nothing wrote it before the lock existed) and confirm a
        // rewrite attempt genuinely has no effect.
        begin
            logic [(`WORD_SIZE-1):0] pmpaddr1_before;
            read_csr(CSR_ADDR_PMPADDR1, pmpaddr1_before);
            write_csr(CSR_ADDR_PMPADDR1, ~pmpaddr1_before);  // attempt to rewrite -- must be refused
            read_csr(CSR_ADDR_PMPADDR1, rdata);
            check("PMP TOR-preceding-lock: pmpaddr1 refuses rewrite once region2 is L=1,A=TOR",
                rdata, pmpaddr1_before);
        end
        // pmpaddr2 (region2's OWN address) is ALSO locked here -- but via
        // the ordinary same-region L-bit rule (region2 itself has L=1),
        // not the TOR-preceding rule this step is isolating. Both rules
        // compose (a locked TOR region locks its own address AND the
        // preceding region's), so this is the expected, not a gap.
        begin
            logic [(`WORD_SIZE-1):0] pmpaddr2_before;
            read_csr(CSR_ADDR_PMPADDR2, pmpaddr2_before);
            write_csr(CSR_ADDR_PMPADDR2, ~pmpaddr2_before);
            read_csr(CSR_ADDR_PMPADDR2, rdata);
            check("PMP TOR-preceding-lock: pmpaddr2 is ALSO locked, via the ordinary same-region rule",
                rdata, pmpaddr2_before);
        end
        write_csr(CSR_ADDR_PMPADDR3, 64'hFFFF_FFFF_FFFF_FFFF);
        read_csr(CSR_ADDR_PMPADDR3, rdata);
        check("PMP TOR-preceding-lock: pmpaddr3 (unrelated region) stays writable",
            rdata, PMPADDR_RESET_ALL_MATCH);

        // 6. Top-10-bits-always-0 on every pmpaddr register, regardless
        //    of what's written to them.
        write_csr(CSR_ADDR_PMPADDR0, {`WORD_SIZE{1'b1}});
        read_csr(CSR_ADDR_PMPADDR0, rdata);
        check("PMP pmpaddr0 top 10 bits always read 0", rdata[63:54], 10'b0);

        // 7. o_mstatus_mprv readback tracks a direct mstatus bit-17
        //    write -- proves the new export, independent of any
        //    consumer existing yet (core.sv wires this up in a later
        //    milestone).
        write_csr(CSR_ADDR_MSTATUS, (`WORD_SIZE'(1) << MPRV_BIT));
        check("PMP: o_mstatus_mprv tracks a direct mstatus write", mstatus_mprv_w, 1'b1);
        write_csr(CSR_ADDR_MSTATUS, `WORD_SIZE'(0));
        check("PMP: o_mstatus_mprv clears when mstatus.MPRV is cleared", mstatus_mprv_w, 1'b0);

        /*
         * ===================================================================
         * PMP+PLIC plan Milestone 3: mip.MEIP (bit 11)/mip.SEIP (bit 9) are
         * live combinational functions of i_meip/i_seip, generalizing bit
         * 7's own Milestone 5 treatment above -- same live-no-clock-edge
         * tracking, same sip-delegation-gating (mideleg, not the external
         * signal alone, controls sip visibility), same "a direct all-1s
         * software write never sticks" property. No separate dut.mip_q
         * hierarchical peek down here -- section 20 above was EXTENDED to
         * check bits 9/11 alongside its existing bit-7 check (same single
         * `~64'hA80` mask expression covers all three bits at once, and a
         * bug narrowing that mask would otherwise be invisible to every
         * black-box mip/sip read here, since mip_effective's read-side
         * override hides mip_q's raw storage regardless).
         * ===================================================================
         */
        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(0));
        write_csr(CSR_ADDR_MIP, `WORD_SIZE'(0));

        meip = 0; seip = 0;
        read_csr(CSR_ADDR_MIP, rdata);
        check("mip bits 9/11 read 0 with i_seip=i_meip=0", `WORD_SIZE'({rdata[11], rdata[9]}), `WORD_SIZE'(0));

        meip = 1; seip = 1;  // direct signal change -- no write_csr, no clock edge
        read_csr(CSR_ADDR_MIP, rdata);
        check("mip bit 11 reads 1 immediately when i_meip=1, no clock edge involved",
              `WORD_SIZE'(rdata[11]), `WORD_SIZE'(1));
        check("mip bit 9 reads 1 immediately when i_seip=1, no clock edge involved",
              `WORD_SIZE'(rdata[9]), `WORD_SIZE'(1));
        check("o_mip control-plane output live-tracks i_meip/i_seip the same as CSR_ADDR_MIP",
              `WORD_SIZE'({mip_w[11], mip_w[9]}), `WORD_SIZE'(2'b11));

        /* sip view: with mideleg bits 9/11 still 0, sip must NOT show
         * either bit even though both external signals are asserted. */
        read_csr(CSR_ADDR_SIP, rdata);
        check("sip bits 9/11 stay 0 when mideleg doesn't delegate them, i_meip=i_seip=1",
              `WORD_SIZE'({rdata[11], rdata[9]}), `WORD_SIZE'(0));

        /* Delegate bit 9 (SEI) only -- sip's view must show bit 9 but NOT
         * bit 11, proving the two bits are independently gated by their
         * own mideleg bit, not a shared/aliased one. */
        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(1) << 9);
        read_csr(CSR_ADDR_SIP, rdata);
        check("sip bit 9 shows through once mideleg[9] delegates it", `WORD_SIZE'(rdata[9]), `WORD_SIZE'(1));
        check("sip bit 11 still hidden -- mideleg[11] not set", `WORD_SIZE'(rdata[11]), `WORD_SIZE'(0));

        meip = 0; seip = 0;
        write_csr(CSR_ADDR_MIDELEG, `WORD_SIZE'(0));  // clean up

        /* A direct all-1s software write to mip must not make bits 9/11
         * stick -- same live-override reasoning as bit 7's own section 19. */
        write_csr(CSR_ADDR_MIP, {`WORD_SIZE{1'b1}});
        read_csr(CSR_ADDR_MIP, rdata);
        check("mip all-1s software write: bits 9/11 read back as i_seip/i_meip (0), not 1",
              `WORD_SIZE'({rdata[11], rdata[9]}), `WORD_SIZE'(0));
        write_csr(CSR_ADDR_MIP, `WORD_SIZE'(0));  // clean up

        /*
         * ===================================================================
         * Sv39 staged plan, Milestone 1: satp's real WARL/MODE structuring
         * and the new o_satp/o_mstatus_sum/o_mstatus_mxr/o_mstatus_tvm
         * control-plane exports. No page-table walker exists yet in
         * core.sv (Milestone 3) -- this section proves the CSR-side
         * storage/export shape alone, same "prove the plumbing before the
         * consumer exists" precedent every earlier CSR-first-half
         * milestone (mip's MTIP/MEIP/SEIP splice, PMP's pmpcfg0/pmpaddr)
         * already established.
         * ===================================================================
         */

        // 1. Reset: satp reads 0 (MODE=Bare) after a fresh reset.
        rst = 1; @(posedge clk); #1; @(posedge clk); #1; rst = 0;
        read_csr(CSR_ADDR_SATP, rdata);
        check("Sv39: satp reads 0 (MODE=Bare) after reset", rdata, `WORD_SIZE'(0));

        // 2. Plain WARL round trip with MODE=Sv39 (8): PPN lands verbatim,
        //    ASID (bits[59:44]) is forced to 0 in storage even though the
        //    write attempts to set every ASID bit.
        write_csr(CSR_ADDR_SATP, {4'd8, 16'hFFFF, 44'h0_0000_1234});
        read_csr(CSR_ADDR_SATP, rdata);
        check("Sv39: satp MODE=Sv39 write lands, PPN verbatim", rdata[43:0], 44'h0_0000_1234);
        check("Sv39: satp MODE reads back 8 (Sv39)", rdata[63:60], 4'd8);
        check("Sv39: satp ASID forced to 0 in storage despite an all-1s ASID write",
              rdata[59:44], 16'b0);

        // 3. MODE=Bare (0) round trip -- the other legal value.
        write_csr(CSR_ADDR_SATP, {4'd0, 16'b0, 44'h0_0000_5678});
        read_csr(CSR_ADDR_SATP, rdata);
        check("Sv39: satp MODE=Bare write also lands", rdata, {4'd0, 16'b0, 44'h0_0000_5678});

        // 4. The all-or-nothing property, specifically: a write with an
        //    unsupported MODE (Sv32=1, a real RISC-V mode this core just
        //    doesn't implement) must leave satp COMPLETELY unchanged --
        //    not a per-field clamp that still lets the PPN through. Reuses
        //    the Sv39 value from step 2's own write as the "before" state,
        //    re-established here so this check doesn't depend on step 3
        //    having run first.
        write_csr(CSR_ADDR_SATP, {4'd8, 16'b0, 44'h0_0000_1234});
        write_csr(CSR_ADDR_SATP, {4'd1, 16'b0, 44'h0_0000_9999});  // MODE=1 (Sv32) -- unsupported
        read_csr(CSR_ADDR_SATP, rdata);
        check("Sv39: unsupported-MODE write leaves satp COMPLETELY unchanged (MODE)",
              rdata[63:60], 4'd8);
        check("Sv39: unsupported-MODE write leaves satp COMPLETELY unchanged (PPN, not the new write's value)",
              rdata[43:0], 44'h0_0000_1234);

        // 5. o_mstatus_sum/o_mstatus_mxr/o_mstatus_tvm each track a direct
        //    mstatus bit write independently, mirroring o_mstatus_mprv's
        //    own step-7 precedent above.
        write_csr(CSR_ADDR_MSTATUS, (`WORD_SIZE'(1) << SUM_BIT));
        check("Sv39: o_mstatus_sum tracks a direct mstatus.SUM write", mstatus_sum_w, 1'b1);
        check("Sv39: o_mstatus_mxr stays 0 while only SUM is set", mstatus_mxr_w, 1'b0);
        check("Sv39: o_mstatus_tvm stays 0 while only SUM is set", mstatus_tvm_w, 1'b0);
        write_csr(CSR_ADDR_MSTATUS, `WORD_SIZE'(0));
        check("Sv39: o_mstatus_sum clears when mstatus.SUM is cleared", mstatus_sum_w, 1'b0);

        write_csr(CSR_ADDR_MSTATUS, (`WORD_SIZE'(1) << MXR_BIT));
        check("Sv39: o_mstatus_mxr tracks a direct mstatus.MXR write", mstatus_mxr_w, 1'b1);
        write_csr(CSR_ADDR_MSTATUS, `WORD_SIZE'(0));
        check("Sv39: o_mstatus_mxr clears when mstatus.MXR is cleared", mstatus_mxr_w, 1'b0);

        write_csr(CSR_ADDR_MSTATUS, (`WORD_SIZE'(1) << TVM_BIT));
        check("Sv39: o_mstatus_tvm tracks a direct mstatus.TVM write", mstatus_tvm_w, 1'b1);
        write_csr(CSR_ADDR_MSTATUS, `WORD_SIZE'(0));
        check("Sv39: o_mstatus_tvm clears when mstatus.TVM is cleared", mstatus_tvm_w, 1'b0);

        $display("");
        $display("csr_file_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("csr_file_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
