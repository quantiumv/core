// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, branches and jumps
 *
 * Adds the next-PC mux on top of core_alu_ops_tb's plain path.
 *
 * Every "branch taken" case below uses a skip-sentinel-then-escape
 * pattern, not just a skip: the sentinel write happens if the branch is
 * WRONGLY not taken, followed by an unconditional jump PAST the "landed
 * correctly" instruction. Without the escape jump, a branch that never
 * takes at all would still fall through both instructions sequentially
 * and end up looking identical to a correctly-taken branch (the sentinel
 * gets overwritten by the "landed" value either way) -- the escape jump
 * is what makes the two cases actually distinguishable.
 */
module core_branch_jump_tb;

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
         * addr  idx  instruction                    notes
         *  0     0   addi x1,x0,1
         *  4     1   addi x2,x0,1
         *  8     2   beq  x1,x2,12      -> 20        beq IS taken (1==1)
         * 12     3   addi x3,x0,111                  sentinel: reached only if beq wrongly not-taken
         * 16     4   jal  x0,8          -> 24         escape, only reached from idx3
         * 20     5   addi x3,x0,222                  correct landing; falls through to idx6
         * 24     6   addi x4,x0,-1
         * 28     7   addi x5,x0,1
         * 32     8   blt  x4,x5,12      -> 44         blt IS taken (signed -1 < 1)
         * 36     9   addi x6,x0,111                  sentinel
         * 40    10   jal  x0,8          -> 48         escape
         * 44    11   addi x6,x0,222                  correct landing; falls through to idx12
         * 48    12   bltu x4,x5,12      -> 60         bltu is NOT taken (unsigned huge < 1 is false)
         * 52    13   addi x7,x0,222                  correct fallthrough (bltu not taken)
         * 56    14   jal  x0,8          -> 64         escape, only reached from idx13's correct path
         * 60    15   addi x7,x0,111                  wrong-landing zone; reached only if bltu wrongly taken
         * 64    16   jal  x8,8          -> 72         link(x8) = 64+4 = 68
         * 68    17   addi x9,x0,111                  skipped by the jal above
         * 72    18   addi x11,x0,78                  jal lands here
         * 76    19   jalr x10,x11,7     raw=78+7=85(odd) -> cleared 84; link(x10)=76+4=80
         * 80    20   addi x12,x0,111                 skipped
         * 84    21   addi x12,x0,222                 jalr lands here
         * 88    22   ebreak
         */
        sram0.memory[0]  = {encode_i(32'sd1, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                             encode_i(32'sd1, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        sram0.memory[1]  = {encode_i(32'sd111, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM),
                             encode_b(32'sd12, 5'd2, 5'd1, 3'b000, `OPC_BRANCH)}; // beq
        sram0.memory[2]  = {encode_i(32'sd222, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM),
                             encode_j(32'sd8, 5'd0, `OPC_JAL)};
        sram0.memory[3]  = {encode_i(32'sd1, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM),
                             encode_i(-32'sd1, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM)};
        sram0.memory[4]  = {encode_i(32'sd111, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM),
                             encode_b(32'sd12, 5'd5, 5'd4, 3'b100, `OPC_BRANCH)}; // blt
        sram0.memory[5]  = {encode_i(32'sd222, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM),
                             encode_j(32'sd8, 5'd0, `OPC_JAL)};
        sram0.memory[6]  = {encode_i(32'sd222, 5'd0, 3'b000, 5'd7, `OPC_OP_IMM),
                             encode_b(32'sd12, 5'd5, 5'd4, 3'b110, `OPC_BRANCH)}; // bltu
        sram0.memory[7]  = {encode_i(32'sd111, 5'd0, 3'b000, 5'd7, `OPC_OP_IMM),
                             encode_j(32'sd8, 5'd0, `OPC_JAL)};
        sram0.memory[8]  = {encode_i(32'sd111, 5'd0, 3'b000, 5'd9, `OPC_OP_IMM),
                             encode_j(32'sd8, 5'd8, `OPC_JAL)};
        sram0.memory[9]  = {encode_i(32'sd7, 5'd11, 3'b000, 5'd10, `OPC_JALR),
                             encode_i(32'sd78, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM)};
        sram0.memory[10] = {encode_i(32'sd222, 5'd0, 3'b000, 5'd12, `OPC_OP_IMM),
                             encode_i(32'sd111, 5'd0, 3'b000, 5'd12, `OPC_OP_IMM)};
        sram0.memory[11] = {32'b0, // unreachable padding -- halted after idx22, never fetched
                             {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}}; // ebreak

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

        check_reg("x3 (beq taken)",              3, 64'd222);
        check_reg("x6 (blt taken, signed)",       6, 64'd222);
        check_reg("x7 (bltu not taken, unsigned)",7, 64'd222);
        check_reg("x8 (jal link value)",          8, 64'd68);
        check_reg("x9 (skipped by jal)",          9, 64'd0);
        check_reg("x10 (jalr link value)",       10, 64'd80);
        check_reg("x12 (jalr LSB-clear fix)",    12, 64'd222);

        $display("");
        $display("core_branch_jump_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_branch_jump_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
