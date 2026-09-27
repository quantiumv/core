// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, register-immediate / register-register ALU ops
 *
 * First integration test -- exercises the plain fetch -> decode -> ALU ->
 * writeback path only, no branch/jump complexity yet (those are added
 * one at a time by the testbenches after this one).
 *
 * Instructions are hand-encoded via riscv_encode.sv and poked directly
 * into a real wb4_sram instance's memory[] array, packed two 32-bit
 * instructions per 64-bit word (core.sv fetches over the Wishbone bus
 * now, not from a private imem0) -- no riscv64-unknown-elf toolchain
 * dependency for this stage.
 */
module core_alu_ops_tb;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst = 1;

    // Arbitrated bus -- what sram0 actually sees.
    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    // core's fetch port (wbf_*) and mem port (wbm_*).
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
        .wb_mem_sel_o(wbm_sel), .wb_mem_we_o(wbm_we), .wb_mem_cyc_o(wbm_cyc), .wb_mem_stb_o(wbm_stb),
        .wb_mem_ack_i(wbm_ack), .wb_mem_err_i(wbm_err), .wb_mem_lock_o(wbm_lock)
    );

    // core.sv now has separate fetch/mem ports; this merges them onto the
    // harness's single SRAM (fetch and data must share one memory). Mem is
    // m1 so execute wins ties, matching cache_complex.sv's dcache-wins policy.
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

    /* No UART/decoder needed -- this test never touches a memory-mapped
     * peripheral, so core is wired to a single wb4_sram (via
     * fetch_mem_arb0 above). */
    wb4_sram #(.num_words(128)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .ack_o(wb_ack), .err_o(wb_err), .cyc_i(wb_cyc), .stb_i(wb_stb), .we_i(wb_we)
    );

    int pass_count = 0;
    int fail_count = 0;
    task automatic check_reg(string name, int idx, logic [(`WORD_SIZE-1):0] expected);
        if (dut.regfile0.gp_registers[idx] === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, dut.regfile0.gp_registers[idx]);
        end
    endtask

    logic halted = 1'b0;
    always @(posedge clk) if (dut.trap_taken && dut.is_ebreak) halted <= 1'b1;

    initial begin
        #1; // run after wb4_sram's own time-0 init (zero-fill + $readmemh) -- see core_wb_tb.sv

        /*
         * addi x1, x0, 5        x1 = 5
         * addi x2, x0, -3       x2 = -3  (negative I-immediate sign-extension)
         * add  x3, x1, x2       x3 = 5 + (-3) = 2
         * sub  x4, x1, x2       x4 = 5 - (-3) = 8
         * slti x5, x2, 0        x5 = (x2 < 0) ? 1 : 0 = 1  (signed compare, negative operand)
         * slli x6, x1, 2        x6 = 5 << 2 = 20  (shamt-routing regression: the old bug read
         *                                          the whole imm field as shamt, not just bits[24:20])
         * srai x7, x2, 1        x7 = (-3) >>> 1 = -2  (needs BOTH the shamt fix and the ALU's
         *                                              SRA fix to land on the right answer)
         * ebreak
         */
        sram0.memory[0] = {encode_i(-32'sd3, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                            encode_i(32'sd5, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        sram0.memory[1] = {encode_r(7'b0100000, 5'd2, 5'd1, 3'b000, 5'd4, `OPC_OP),
                            encode_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, `OPC_OP)};
        sram0.memory[2] = {encode_shift64(6'b000000, 6'd2, 5'd1, 3'b001, 5'd6, `OPC_OP_IMM),
                            encode_i(32'sd0, 5'd2, 3'b010, 5'd5, `OPC_OP_IMM)};
        sram0.memory[3] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM}, // ebreak
                            encode_shift64(6'b010000, 6'd1, 5'd2, 3'b101, 5'd7, `OPC_OP_IMM)};

        @(posedge clk); #1;
        rst = 0;

        fork
            wait (halted === 1'b1);
            begin
                repeat (150) @(posedge clk);
                $display("TIMEOUT: EBREAK trap never fired");
                $finish;
            end
        join_any
        #1;

        check_reg("x1 (addi positive)",    1, 64'd5);
        check_reg("x2 (addi negative)",    2, -64'sd3);
        check_reg("x3 (add)",              3, 64'd2);
        check_reg("x4 (sub)",              4, 64'd8);
        check_reg("x5 (slti, neg < 0)",    5, 64'd1);
        check_reg("x6 (slli shamt route)", 6, 64'd20);
        check_reg("x7 (srai neg, fixed)",  7, -64'sd2);

        $display("");
        $display("core_alu_ops_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_alu_ops_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
