// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, LUI / AUIPC
 *
 * Adds only the U-type operand-mux subtlety on top of core_alu_ops_tb's
 * plain path -- see the AUIPC comment in core.sv for the full story on
 * why AUIPC needs both ALU operands swapped, not just A.
 */
module core_upper_imm_tb;

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
         * lui x1, 0xFFFFF      x1 = 0xFFFFFFFFFFFFF000  (bit 19 set -> must sign-extend
         *                       negative; the old bug never shifted at all, so this would
         *                       have produced 0x00000000000FFFFF instead)
         * lui x2, 0x00001      x2 = 0x0000000000001000  (bit 19 clear -> stays positive,
         *                       contrasting case)
         * auipc x3, 0x00001    at PC=0x8: x3 = 0x8 + 0x1000 = 0x1008
         * ebreak
         */
        sram0.memory[0] = {encode_u(20'h00001, 5'd2, `OPC_LUI),
                            encode_u(20'hFFFFF, 5'd1, `OPC_LUI)};
        sram0.memory[1] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM}, // ebreak
                            encode_u(20'h00001, 5'd3, `OPC_AUIPC)};

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

        check_reg("x1 (lui, bit19 set -> negative)", 1, 64'hFFFFFFFFFFFFF000);
        check_reg("x2 (lui, bit19 clear -> positive)", 2, 64'h0000000000001000);
        check_reg("x3 (auipc, pc + imm)", 3, 64'h0000000000001008);

        $display("");
        $display("core_upper_imm_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_upper_imm_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
