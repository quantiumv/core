// One line per retirement, for differential auditing (verification/
// lockstep/sail_diff.py) and reused by the P3.4 lockstep harness. Same
// flat-SRAM topology as act_runner_tb.sv (fetch + mem through
// wb_arbiter2 into one wb4_sram) -- this generator's own corpus never
// needs a cache model. Requires -DRISCV_FORMAL (adds core.sv's RVFI tap
// and CSR mirrors only -- verified elsewhere in this repo to have zero
// effect on the non-formal build).
//
// Plusargs: +HEXFILE=<path> +TOHOST_ADDR=<hex, no 0x> +TIMEOUT=<cycles>
// (same convention as act_runner_tb.sv). Prints one "rvfi ..." line per
// retirement to stdout, then "RVFI_DONE tohost=<val>" once the tohost
// word goes nonzero (or "RVFI_TIMEOUT" if it never does).
module rvfi_tracer;
    localparam int NUM_WORDS = 131072; // 1 MiB, matching qvgen.py's image
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;
    logic [31:0] wbf_addr;
    logic [63:0] wbf_dat_s2m;
    logic        wbf_cyc, wbf_stb, wbf_ack, wbf_err;
    logic [31:0] wbm_addr;
    logic [63:0] wbm_dat_m2s, wbm_dat_s2m;
    logic [7:0]  wbm_sel;
    logic        wbm_we, wbm_cyc, wbm_stb, wbm_ack, wbm_err, wbm_lock;

    // -- RVFI taps (see core.sv's own `ifdef RISCV_FORMAL port block) --
    logic        rvfi_valid;
    logic [63:0] rvfi_order;
    logic [31:0] rvfi_insn;
    logic        rvfi_trap;
    logic        rvfi_halt;
    logic        rvfi_intr;
    logic [1:0]  rvfi_mode;
    logic [1:0]  rvfi_ixl;
    logic [4:0]  rvfi_rs1_addr, rvfi_rs2_addr;
    logic [63:0] rvfi_rs1_rdata, rvfi_rs2_rdata;
    logic [4:0]  rvfi_rd_addr;
    logic [63:0] rvfi_rd_wdata;
    logic [63:0] rvfi_pc_rdata, rvfi_pc_wdata;
    logic [63:0] rvfi_mem_addr;
    logic [7:0]  rvfi_mem_rmask, rvfi_mem_wmask;
    logic [63:0] rvfi_mem_rdata, rvfi_mem_wdata;
    logic [63:0] rvfi_csr_mepc_rmask, rvfi_csr_mepc_wmask, rvfi_csr_mepc_rdata, rvfi_csr_mepc_wdata;
    logic [63:0] rvfi_csr_mcause_rmask, rvfi_csr_mcause_wmask, rvfi_csr_mcause_rdata, rvfi_csr_mcause_wdata;
    logic [63:0] rvfi_csr_sepc_rmask, rvfi_csr_sepc_wmask, rvfi_csr_sepc_rdata, rvfi_csr_sepc_wdata;
    logic [63:0] rvfi_csr_scause_rmask, rvfi_csr_scause_wmask, rvfi_csr_scause_rdata, rvfi_csr_scause_wdata;
    logic [63:0] rvfi_csr_pmpcfg0_rmask, rvfi_csr_pmpcfg0_wmask, rvfi_csr_pmpcfg0_rdata, rvfi_csr_pmpcfg0_wdata;
    logic [63:0] rvfi_csr_pmpaddr0_rmask, rvfi_csr_pmpaddr0_wmask, rvfi_csr_pmpaddr0_rdata, rvfi_csr_pmpaddr0_wdata;
    logic [63:0] rvfi_csr_medeleg_rmask, rvfi_csr_medeleg_wmask, rvfi_csr_medeleg_rdata, rvfi_csr_medeleg_wdata;
    logic [63:0] rvfi_csr_satp_rmask, rvfi_csr_satp_wmask, rvfi_csr_satp_rdata, rvfi_csr_satp_wdata;
    logic        rvfi_any_trap_taken, rvfi_any_debug_entry;

    // Named connections only for wb_fetch/wb_mem + every RVFI port;
    // everything else (icache_flush_o, debug/DM/progbuf/interrupt
    // ports) is left unconnected -- every input among them has an ANSI
    // default (see core.sv's own port list), and the outputs simply
    // aren't observed here, matching this project's own established
    // minimal-harness convention (see e.g. testbench/act_runner_tb.sv).
    core dut (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(wbf_addr), .wb_fetch_cyc_o(wbf_cyc), .wb_fetch_stb_o(wbf_stb),
        .wb_fetch_dat_i(wbf_dat_s2m), .wb_fetch_ack_i(wbf_ack), .wb_fetch_err_i(wbf_err),
        .wb_mem_addr_o(wbm_addr), .wb_mem_dat_o(wbm_dat_m2s), .wb_mem_dat_i(wbm_dat_s2m),
        .wb_mem_sel_o(wbm_sel), .wb_mem_we_o(wbm_we), .wb_mem_cyc_o(wbm_cyc), .wb_mem_stb_o(wbm_stb),
        .wb_mem_ack_i(wbm_ack), .wb_mem_err_i(wbm_err), .wb_mem_lock_o(wbm_lock),
        .rvfi_valid(rvfi_valid), .rvfi_order(rvfi_order), .rvfi_insn(rvfi_insn),
        .rvfi_trap(rvfi_trap), .rvfi_halt(rvfi_halt), .rvfi_intr(rvfi_intr),
        .rvfi_mode(rvfi_mode), .rvfi_ixl(rvfi_ixl),
        .rvfi_rs1_addr(rvfi_rs1_addr), .rvfi_rs2_addr(rvfi_rs2_addr),
        .rvfi_rs1_rdata(rvfi_rs1_rdata), .rvfi_rs2_rdata(rvfi_rs2_rdata),
        .rvfi_rd_addr(rvfi_rd_addr), .rvfi_rd_wdata(rvfi_rd_wdata),
        .rvfi_pc_rdata(rvfi_pc_rdata), .rvfi_pc_wdata(rvfi_pc_wdata),
        .rvfi_mem_addr(rvfi_mem_addr), .rvfi_mem_rmask(rvfi_mem_rmask),
        .rvfi_mem_wmask(rvfi_mem_wmask), .rvfi_mem_rdata(rvfi_mem_rdata),
        .rvfi_mem_wdata(rvfi_mem_wdata),
        .rvfi_csr_mepc_rmask(rvfi_csr_mepc_rmask), .rvfi_csr_mepc_wmask(rvfi_csr_mepc_wmask),
        .rvfi_csr_mepc_rdata(rvfi_csr_mepc_rdata), .rvfi_csr_mepc_wdata(rvfi_csr_mepc_wdata),
        .rvfi_csr_mcause_rmask(rvfi_csr_mcause_rmask), .rvfi_csr_mcause_wmask(rvfi_csr_mcause_wmask),
        .rvfi_csr_mcause_rdata(rvfi_csr_mcause_rdata), .rvfi_csr_mcause_wdata(rvfi_csr_mcause_wdata),
        .rvfi_csr_sepc_rmask(rvfi_csr_sepc_rmask), .rvfi_csr_sepc_wmask(rvfi_csr_sepc_wmask),
        .rvfi_csr_sepc_rdata(rvfi_csr_sepc_rdata), .rvfi_csr_sepc_wdata(rvfi_csr_sepc_wdata),
        .rvfi_csr_scause_rmask(rvfi_csr_scause_rmask), .rvfi_csr_scause_wmask(rvfi_csr_scause_wmask),
        .rvfi_csr_scause_rdata(rvfi_csr_scause_rdata), .rvfi_csr_scause_wdata(rvfi_csr_scause_wdata),
        .rvfi_csr_pmpcfg0_rmask(rvfi_csr_pmpcfg0_rmask), .rvfi_csr_pmpcfg0_wmask(rvfi_csr_pmpcfg0_wmask),
        .rvfi_csr_pmpcfg0_rdata(rvfi_csr_pmpcfg0_rdata), .rvfi_csr_pmpcfg0_wdata(rvfi_csr_pmpcfg0_wdata),
        .rvfi_csr_pmpaddr0_rmask(rvfi_csr_pmpaddr0_rmask), .rvfi_csr_pmpaddr0_wmask(rvfi_csr_pmpaddr0_wmask),
        .rvfi_csr_pmpaddr0_rdata(rvfi_csr_pmpaddr0_rdata), .rvfi_csr_pmpaddr0_wdata(rvfi_csr_pmpaddr0_wdata),
        .rvfi_csr_medeleg_rmask(rvfi_csr_medeleg_rmask), .rvfi_csr_medeleg_wmask(rvfi_csr_medeleg_wmask),
        .rvfi_csr_medeleg_rdata(rvfi_csr_medeleg_rdata), .rvfi_csr_medeleg_wdata(rvfi_csr_medeleg_wdata),
        .rvfi_csr_satp_rmask(rvfi_csr_satp_rmask), .rvfi_csr_satp_wmask(rvfi_csr_satp_wmask),
        .rvfi_csr_satp_rdata(rvfi_csr_satp_rdata), .rvfi_csr_satp_wdata(rvfi_csr_satp_wdata),
        .rvfi_any_trap_taken(rvfi_any_trap_taken), .rvfi_any_debug_entry(rvfi_any_debug_entry)
    );

    wb_arbiter2 fetch_mem_arb0 (
        .clk(clk), .rst(rst),
        .m0_addr_i(wbf_addr), .m0_dat_i(64'b0), .m0_dat_o(wbf_dat_s2m),
        .m0_sel_i({8{wbf_cyc}}), .m0_we_i(1'b0), .m0_cyc_i(wbf_cyc), .m0_stb_i(wbf_stb),
        .m0_ack_o(wbf_ack), .m0_err_o(wbf_err),
        .m1_addr_i(wbm_addr), .m1_dat_i(wbm_dat_m2s), .m1_dat_o(wbm_dat_s2m),
        .m1_sel_i(wbm_sel), .m1_we_i(wbm_we), .m1_cyc_i(wbm_cyc), .m1_stb_i(wbm_stb),
        .m1_ack_o(wbm_ack), .m1_err_o(wbm_err), .m1_lock_i(wbm_lock),
        .addr_o(wb_addr), .dat_o(wb_dat_m2s), .dat_i(wb_dat_s2m),
        .sel_o(wb_sel), .we_o(wb_we), .cyc_o(wb_cyc), .stb_o(wb_stb),
        .ack_i(wb_ack), .err_i(wb_err),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_grant()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    wb4_sram #(.num_words(NUM_WORDS)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .ack_o(wb_ack), .err_o(wb_err), .cyc_i(wb_cyc), .stb_i(wb_stb), .we_i(wb_we)
    );

    initial begin
        string hex_path;
        logic [31:0] tohost_addr;
        int max_cycles;
        int n;
        logic [63:0] tohost_val;
        if (!$value$plusargs("HEXFILE=%s", hex_path)) hex_path = "";
        if (!$value$plusargs("TOHOST_ADDR=%h", tohost_addr)) tohost_addr = 32'b0;
        if (!$value$plusargs("TIMEOUT=%d", max_cycles)) max_cycles = 200000;
        #1;
        $readmemh(hex_path, sram0.memory);
        @(posedge clk); #1;
        rst = 0;
        n = 0;
        while (n < max_cycles) begin
            @(posedge clk); #1;
            if (rvfi_valid) begin
                // trap_val: core.sv's own LIVE combinational wire (not
                // mtval_q/stval_q, which are registered and lag this
                // cycle by one -- see this project's own established
                // "read the live wire, not the _q" convention). Valid
                // only when rvfi_trap is set; 0 otherwise, matching
                // Sail's own "tval is only meaningful for a real trap"
                // convention in its --trace-exception output.
                // cause: dut.route_to_s (core.sv's own LIVE "did this
                // trap/interrupt route to S or M" signal, already
                // combining trap_to_s/interrupt_to_s the same way
                // csr_file0's own i_trap_to_s input does) selects
                // mcause_wdata vs scause_wdata DETERMINISTICALLY.
                //
                // A REAL bug this fixes, found by direct comparison
                // against Sail: the previous version picked whichever
                // of mcause_wdata/scause_wdata DIFFERED from its own
                // rdata -- which silently reports cause=0 whenever the
                // SAME cause fires twice in a row (e.g. two illegal
                // instructions back to back with nothing delegated
                // in between): the second write doesn't change the
                // value, so nothing looked "written" even though a
                // real trap, with a real (unchanged-but-rewritten)
                // cause, genuinely occurred.
                $display("rvfi order=%0d pc_rdata=%h pc_wdata=%h insn=%h mode=%0d trap=%b intr=%b cause=%h tval=%h rd_addr=%0d rd_wdata=%h rs1_addr=%0d rs1_rdata=%h rs2_addr=%0d rs2_rdata=%h mem_addr=%h mem_rmask=%h mem_wmask=%h mem_rdata=%h mem_wdata=%h",
                    rvfi_order, rvfi_pc_rdata, rvfi_pc_wdata, rvfi_insn, rvfi_mode,
                    rvfi_trap, rvfi_intr,
                    rvfi_trap ? (dut.route_to_s ? rvfi_csr_scause_wdata : rvfi_csr_mcause_wdata) : 64'b0,
                    (rvfi_trap ? dut.trap_val : 64'b0),
                    rvfi_rd_addr, rvfi_rd_wdata, rvfi_rs1_addr, rvfi_rs1_rdata,
                    rvfi_rs2_addr, rvfi_rs2_rdata, rvfi_mem_addr, rvfi_mem_rmask,
                    rvfi_mem_wmask, rvfi_mem_rdata, rvfi_mem_wdata);
            end
            tohost_val = sram0.memory[tohost_addr[31:3]];
            if (tohost_val != 64'b0) begin
                $display("RVFI_DONE tohost=%h", tohost_val);
                $finish;
            end
            n++;
        end
        $display("RVFI_TIMEOUT");
        $finish;
    end
endmodule
