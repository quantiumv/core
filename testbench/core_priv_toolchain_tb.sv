// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's U/S/M privilege-mode support against a REAL
 * toolchain-assembled and -linked program (firmware/priv_test.s), as
 * opposed to testbench/core_priv_tb.sv's hand-packed instruction
 * encodings. Same wiring spirit as core_csr_toolchain_tb.sv/
 * core_m_toolchain_tb.sv (a real wb4_sram instance, core wired directly
 * to it as the sole Wishbone master) but even simpler: no UART needed,
 * since priv_test.s never issues a load/store -- it's pure register/CSR/
 * control-flow traffic, same reasoning the other two toolchain
 * testbenches already document for themselves.
 *
 * wb4_sram.sv's own time-0 initial block unconditionally zero-fills then
 * $readmemh's firmware/crt0.hex (the hello-world image) into its
 * memory -- see that file's header. This testbench doesn't want that
 * image; it wants firmware/priv_test.hex instead. Rather than editing
 * wb4_sram.sv (shared by every other testbench), a second $readmemh
 * right here overwrites the SRAM with the real image once wb4_sram's own
 * init is done, before reset is released -- same #1-past-time-0 delay
 * convention core_csr_toolchain_tb.sv/core_m_toolchain_tb.sv use for the
 * identical reason: guarantee ordering against an unrelated zero-time
 * initial block instead of racing it.
 *
 * Instantiated at wb4_sram's default num_words (4096, 32KB), matching
 * core_csr_toolchain_tb.sv/core_m_toolchain_tb.sv and design/soc.sv's own
 * instantiation -- this test loads a real program linked against
 * firmware/link.ld, which reserves the full 32KB RAM region.
 *
 * Uses the shared testbench/ infrastructure (check_lib.sv, halt_wait.sv),
 * same as every testbench written since that environment was built.
 * TIMEOUT_CYCLES_SMALL (300 cycles): this program is a linear sequence of
 * roughly two dozen real instructions plus two short trap handlers and
 * two traps -- no loops, no multi-cycle divides -- comfortably inside the
 * same tier core_csr_toolchain_tb.sv already uses for a similarly-shaped
 * real-toolchain program.
 *
 * firmware/priv_test.s provides its own main:, called from crt0.s exactly
 * like hello.c's -- see that file's header/inline comments for the full
 * instruction-by-instruction derivation of the expected s1-s5 values
 * below. ra/sp/gp/tp are untouched by priv_test.s, so `ret` falls back
 * into crt0.s's trailing ebreak, halting the core the same way every
 * other firmware image in this repo does -- regardless of which
 * privilege mode is current at that point (EBREAK's halt latch has no
 * privilege gate, see core.sv).
 */
module core_priv_toolchain_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    // core's own two ports: wbf_* = fetch (read-only), wbm_* = mem.
    logic [31:0] wbf_addr;
    logic [63:0] wbf_dat_s2m;
    logic        wbf_cyc, wbf_stb, wbf_ack, wbf_err;
    logic [31:0] wbm_addr;
    logic [63:0] wbm_dat_m2s, wbm_dat_s2m;
    logic [7:0]  wbm_sel;
    logic        wbm_we, wbm_cyc, wbm_stb, wbm_ack, wbm_err, wbm_lock;

    core dut (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(wbf_addr), .wb_fetch_cyc_o(wbf_cyc), .wb_fetch_stb_o(wbf_stb),
        .wb_fetch_dat_i(wbf_dat_s2m), .wb_fetch_ack_i(wbf_ack), .wb_fetch_err_i(wbf_err),
        .wb_mem_addr_o(wbm_addr), .wb_mem_dat_o(wbm_dat_m2s), .wb_mem_dat_i(wbm_dat_s2m),
        .wb_mem_sel_o(wbm_sel), .wb_mem_we_o(wbm_we), .wb_mem_cyc_o(wbm_cyc),
        .wb_mem_stb_o(wbm_stb), .wb_mem_ack_i(wbm_ack), .wb_mem_err_i(wbm_err),
        .wb_mem_lock_o(wbm_lock)
    );

    /* core.sv now has separate fetch and mem ports; this merges them onto
     * the harness's single SRAM (wb_* above = what sram0 sees). mem is m1
     * so execute wins ties. Fetch never writes: sel mirrors the old core's
     * 8'hFF-while-fetching, 0-when-idle behavior. */
    wb_arbiter2 fetch_mem_arb0 (
        .clk(clk), .rst(rst),
        .m0_addr_i(wbf_addr), .m0_dat_i(64'b0), .m0_dat_o(wbf_dat_s2m),
        .m0_sel_i({8{wbf_cyc}}), .m0_we_i(1'b0), .m0_cyc_i(wbf_cyc), .m0_stb_i(wbf_stb),
        .m0_ack_o(wbf_ack), .m0_err_o(wbf_err),
        .m1_addr_i(wbm_addr), .m1_dat_i(wbm_dat_m2s), .m1_dat_o(wbm_dat_s2m),
        .m1_sel_i(wbm_sel), .m1_we_i(wbm_we), .m1_cyc_i(wbm_cyc), .m1_stb_i(wbm_stb),
        .m1_ack_o(wbm_ack), .m1_err_o(wbm_err), .m1_lock_i(wbm_lock),
        .addr_o(wb_addr), .dat_o(wb_dat_m2s), .dat_i(wb_dat_s2m), .sel_o(wb_sel),
        .we_o(wb_we), .cyc_o(wb_cyc), .stb_o(wb_stb), .ack_i(wb_ack), .err_i(wb_err),
        /* verilator lint_off PINCONNECTEMPTY */ .o_grant() /* verilator lint_on PINCONNECTEMPTY */
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
     * mcause_q/current_priv snapshot, taken on the SAME edge the
     * terminal ebreak's own trap_taken first fires -- NOT read live at
     * check() time. mtvec is never repointed away from M_TRAP_HANDLER by
     * priv_test.s, so crt0.s's own trailing ebreak (a real trap now)
     * bounces right back into it, corrupting mcause_q/current_priv long
     * after this test's own real assertions already happened (same class
     * of bug found and fixed in core_priv_tb.sv/core_c_illegal_trap_tb.sv
     * -- see their own comments for the full story).
     *
     * This capture technique needs no known instruction address (unlike
     * those hand-encoded testbenches): mcause_q's own always_ff writes
     * `mcause_q <= i_trap_cause` on i_trap_taken, non-blocking -- so a
     * SEPARATE always block reading mcause_q on that identical edge
     * (trap_taken && is_ebreak, this ebreak's own commit) sees the
     * PRE-edge value, i.e. whatever mcause_q held from the last real
     * event BEFORE this ebreak's own trap-entry overwrites it -- exactly
     * the value this test wants, for free, regardless of where in the
     * program that terminal ebreak lives.
     */
    logic [63:0] final_mcause_snap;
    logic [1:0]  final_priv_snap;
    logic final_state_captured = 1'b0;
    always @(posedge clk) if (!final_state_captured && dut.trap_taken && dut.is_ebreak) begin
        final_state_captured <= 1'b1;
        final_mcause_snap <= dut.csr_file0.mcause_q;
        final_priv_snap   <= dut.current_priv;
    end

    initial begin
        #1; // see header comment: run after wb4_sram's own time-0 init of crt0.hex
        $readmemh("../firmware/priv_test.hex", sram0.memory);

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "EBREAK trap never fired -- is firmware/priv_test.hex built?");

        /*
         * Expected values, mechanically identical to the derivation
         * documented instruction-by-instruction in firmware/priv_test.s.
         * s1-s5 map to gp_registers[9] and [19:21] -- NOT a contiguous
         * range: x9 is s1, but x10-x17 are the argument registers a0-a7,
         * and only x18-x27 pick back up as s2-s11, per the standard RV64
         * calling convention (same mapping core_csr_toolchain_tb.sv/
         * core_m_toolchain_tb.sv already document for themselves).
         */
        check("s1 (mcause after M-mode ECALL == 11)",            dut.regfile0.gp_registers[9],  64'd11);
        check("s2 (phase 1 marker -- resumed after M-mode trap)", dut.regfile0.gp_registers[18], 64'd111);
        check("s3 (phase 2 marker -- now running in real S-mode code)", dut.regfile0.gp_registers[19], 64'd222);
        check("s4 (scause after delegated S-mode ECALL == 9)",    dut.regfile0.gp_registers[20], 64'd9);
        check("s5 (phase 3 marker -- resumed after delegated S-mode trap)", dut.regfile0.gp_registers[21], 64'd333);

        /*
         * Disambiguating check (register-independent confirmation, same
         * spirit as core_csr_toolchain_tb.sv's own mscratch_q check):
         * mcause is M-only (CSR 0x342, bits[9:8]=11), so priv_test.s
         * itself has no way to re-read it from S-mode without another
         * M-target trap that would overwrite it -- instead, confirm here,
         * directly, that the delegated S-target trap in phase 3 left the
         * M-side mcause_q exactly as phase 1 left it (11), proving
         * trap_to_s correctly routed phase 3's cause into scause_q
         * (already checked above as s4) and nowhere near mcause_q.
         */
        check("final-state sample was captured (sanity on the monitor itself)", {63'b0, final_state_captured}, 64'd1);
        check("mcause_q still 11 post-halt (untouched by the later S-target trap)", final_mcause_snap, 64'd11);
        check("scause_q final value (register-independent confirmation)", dut.csr_file0.scause_q, 64'd9);

        /* Final privilege level: phase 3's delegated ECALL trapped from S and sret'd back to S (SPP captured S at entry) -- never left S after phase 2's bootstrap. */
        check("final current_priv == S", {62'b0, final_priv_snap}, 64'(2'b01));

        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_priv_toolchain_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_priv_toolchain_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
