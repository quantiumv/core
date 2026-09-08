// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's Sv39 virtual-memory support against a REAL
 * toolchain-assembled and -linked program (firmware/sv39_real_test.s),
 * as opposed to every prior Sv39 testbench (testbench/core_sv39_
 * {fetch,mem,tlb,cache}_tb.sv), which all hand-pack page tables and
 * instruction encodings directly into simulation memory. Same wiring
 * spirit as core_priv_toolchain_tb.sv (a real wb4_sram instance, core
 * wired directly to it as the sole Wishbone master, no cache -- this
 * test is about proving the walker itself against real toolchain-
 * generated code, not re-proving Milestone 6's own cache-integration
 * story) and the SAME "second $readmemh, one time unit after wb4_sram's
 * own time-0 init of crt0.hex" convention that file documents in full --
 * see its own header comment for why the #1 delay is load-bearing here
 * too.
 *
 * Instantiated at wb4_sram's default num_words (4096, 32KB), matching
 * core_priv_toolchain_tb.sv and design/soc.sv's own instantiation --
 * this test loads a real program linked against firmware/link.ld, which
 * reserves the full 32KB RAM region (see firmware/sv39_real_test.s's own
 * header for why its ~16KB footprint, all runtime-address-computed, has
 * a large margin against both the image size and _stack_top).
 *
 * TIMEOUT_CYCLES_LARGE: this program includes a real 3-level page-table
 * walk PLUS a real mem-side walk (or TLB hit), each costing several bus
 * cycles beyond the plain instruction-issue cost every other toolchain
 * testbench budgets for -- same tier core_sv39_fetch_tb.sv/
 * core_sv39_mem_tb.sv/core_sv39_tlb_tb.sv already use for walker-
 * involving tests, comfortably larger than TIMEOUT_CYCLES_SMALL (which
 * core_priv_toolchain_tb.sv/core_csr_toolchain_tb.sv use for walker-free
 * programs of a similar instruction count).
 *
 * What this test actually proves, beyond every hand-packed Sv39
 * testbench: that the FULL real-toolchain pipeline (as/ld/objcopy,
 * relocations, li/la pseudo-instruction expansion, real CSR mnemonics
 * including the literal name "satp", and a real `sfence.vma`) produces
 * a program that correctly builds its own page table at runtime and
 * gets genuinely translated by the walker -- not just that the walker
 * behaves correctly against a table the testbench itself constructed by
 * hand. The white-box S_PTW-entry counter below (same technique
 * core_sv39_tlb_tb.sv's own header comment documents in full: a walk
 * stays in S_PTW continuously across all its levels, so counting
 * TRANSITIONS into S_PTW -- not just "was S_PTW ever entered" -- counts
 * "number of separate walks") additionally confirms BOTH streams were
 * genuinely exercised: at least one walk whose ptw_reason_q was
 * PTW_REASON_LO/PTW_REASON_HI (fetch-side, reaching s_mode_target) and
 * at least one whose ptw_reason_q was PTW_REASON_MEM (mem-side, the
 * store+load round trip through s_mode_data) -- the one check that
 * rules out a silent untranslated fallback path succeeding for the
 * wrong reason (e.g. a bug that let mem accesses through unchecked
 * while translation was nominally active).
 */
module core_sv39_realfw_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    core dut (
        .clk(clk), .rst(rst),
        .wb_addr_o(wb_addr), .wb_dat_o(wb_dat_m2s), .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack), .wb_err_i(wb_err)
    );

    wb4_sram sram0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .ack_o(wb_ack), .err_o(wb_err), .cyc_i(wb_cyc), .stb_i(wb_stb), .we_i(wb_we)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    logic halted = 1'b0;
    always @(posedge clk) if (dut.trap_taken && dut.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"

    /*
     * White-box S_PTW-entry counter, split by stream (fetch vs mem),
     * same negedge-sampling discipline testbench/core_sv39_tlb_tb.sv's
     * own ptw_count_X uses (see that file's header for why negedge: it
     * lets state/ptw_reason_q's own non-blocking updates from the DUT's
     * posedge-triggered always_ff settle before this monitor reads
     * them, avoiding a same-edge race against the DUT's own state
     * transition).
     */
    logic ptw_prev = 1'b0;
    int ptw_count_fetch = 0;
    int ptw_count_mem   = 0;
    always @(negedge clk) begin
        if ((dut.state == dut.S_PTW) && !ptw_prev) begin
            if (dut.ptw_reason_q == dut.PTW_REASON_MEM) ptw_count_mem   <= ptw_count_mem + 1;
            else                                        ptw_count_fetch <= ptw_count_fetch + 1;
        end
        ptw_prev <= (dut.state == dut.S_PTW);
    end

    /*
     * current_priv snapshot, taken on the SAME edge the terminal
     * ebreak's own trap_taken first fires -- NOT read live at check()
     * time. Same technique/rationale as core_priv_toolchain_tb.sv's own
     * final_priv_snap: EBREAK is a real trap (jumps to mtvec, resumes
     * execution), and this program's own mtvec still points at
     * m_fallback_handler, whose own trailing ebreak would corrupt a
     * live post-halt read of current_priv if this test's own success
     * path is ever reached a second time. Capturing pre-edge current_priv
     * on the FIRST trap_taken&&is_ebreak pulse distinguishes the two
     * possible halting paths outright: S means s_mode_target's own
     * EBREAK fired (the real, translated S-mode success path -- current
     * privilege was still S the instant that EBREAK committed); M means
     * m_fallback_handler's EBREAK fired instead (an unexpected trap
     * diverted control there, since that handler only ever runs in
     * M-mode).
     */
    logic [1:0] final_priv_snap;
    logic final_priv_captured = 1'b0;
    always @(posedge clk) if (!final_priv_captured && dut.trap_taken && dut.is_ebreak) begin
        final_priv_captured <= 1'b1;
        final_priv_snap     <= dut.current_priv;
    end

    initial begin
        #1; // see header comment: run after wb4_sram's own time-0 init of crt0.hex
        $readmemh("../firmware/sv39_real_test.hex", sram0.memory);

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "EBREAK trap never fired -- is firmware/sv39_real_test.hex built?");

        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        /*
         * s4 (x20) must stay 0 -- it is ONLY ever written by
         * m_fallback_handler, which this program's own control flow
         * should never reach. Checked FIRST and independently of the
         * priv snapshot below: if this fails, s5 (x21, mcause) is the
         * actionable diagnostic for why (not asserted on here -- its
         * value is only meaningful when s4 is nonzero, and printing it
         * unconditionally would just be noise on the success path).
         */
        check("s4 (fallback-handler marker) == 0 -- the defensive fallback was never reached",
              dut.regfile0.gp_registers[20], 64'd0);

        check("final current_priv == S at the terminal EBREAK -- halted via s_mode_target's own EBREAK, not the fallback handler's",
              {62'b0, final_priv_snap}, 64'(2'b01));

        check("s1 (x9) == 0xAA -- real, fetch-side-translated S-mode code genuinely executed",
              dut.regfile0.gp_registers[9], 64'h0AA);

        check("s2 (x18) == 0x12345678 -- the mem-side store+load round trip through the translated data page succeeded",
              dut.regfile0.gp_registers[18], 64'h12345678);

        check("s3 (x19) == 0xC0FFEE -- the whole real-toolchain S-mode sequence ran to completion",
              dut.regfile0.gp_registers[19], 64'hC0FFEE);

        /*
         * The actual proof that real translation happened, not a silent
         * untranslated fallback: the walker's own S_PTW state was
         * genuinely entered at least once for EACH stream. (Exact
         * counts aren't pinned down further than ">=1 each" -- the
         * fetch stream alone could cost anywhere from one walk, if the
         * whole s_mode_target sequence stays cache/TLB-resident for its
         * VPN, up to several, depending on how many distinct dwords its
         * instructions span; the point of this check is stream
         * coverage, not an exact walk count, which the hand-packed
         * Milestone 3/4/5 testbenches already pin down precisely against
         * page tables THEY control.)
         */
        check("at least one real fetch-side S_PTW walk occurred", (ptw_count_fetch >= 1), 1'b1);
        check("at least one real mem-side S_PTW walk occurred",   (ptw_count_mem   >= 1), 1'b1);

        $display("");
        $display("fetch-side S_PTW walks: %0d, mem-side S_PTW walks: %0d", ptw_count_fetch, ptw_count_mem);
        $display("core_sv39_realfw_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_realfw_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
