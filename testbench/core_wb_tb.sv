// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core (Wishbone-master FSM) against real bus slaves
 *
 * Unlike the five core_*_tb.sv testbenches from the single-cycle
 * milestone (which poked instructions into a private imem0 and no longer
 * even compile against this core.sv -- it has no imem0 anymore), this
 * exercises exactly what's NEW in the FSM rewrite: multi-cycle fetch,
 * multi-cycle load/store, and routing through a real wb_addr_decoder to
 * two real slaves (wb4_sram, uart_tx). It deliberately does NOT re-prove
 * individual ALU ops, branch types, or the *W op family -- that datapath logic is
 * unchanged from the single-cycle version and was already proven there.
 * This is the checkpoint before wiring the same four modules into
 * design/soc.sv for real.
 *
 * Instructions are packed two-per-64-bit-word directly into the SRAM's
 * memory[] array (hierarchical poke, same spirit as the old imem0 pokes)
 * -- byte address a's instruction lands in memory[a/8][31:0] if a[2]=0,
 * else memory[a/8][63:32], matching core.sv's own pc[2] half-select.
 *
 * The poke is deliberately delayed by #1 past time 0 so it runs AFTER
 * wb4_sram's own time-0 initial block (zero-fill + $readmemh of whatever
 * firmware/crt0.hex currently contains) has already finished -- both are
 * ordinary zero-time initial blocks with no blocking statements of their
 * own, so by time 1 both are guaranteed complete regardless of which one
 * the simulator happened to start first. Without this, the poke could
 * race wb4_sram's own init and get silently overwritten.
 *
 * Data addresses (0x100, 0x8000) are deliberately clear of the program's
 * own instruction footprint (0x00-0x2C) -- this is a shared Von Neumann
 * memory with no protection, so a data write to an address the program
 * still occupies would self-modify code that's already been fetched
 * (harmless in this particular straight-line run, but confusing to
 * anyone reading the test).
 */
module core_wb_tb;

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

    logic [31:0] ram_addr, uart_addr;
    logic [63:0] ram_dat_o, ram_dat_i, uart_dat_o, uart_dat_i;
    logic [7:0]  ram_sel, uart_sel;
    logic        ram_we, ram_cyc, ram_stb, ram_ack, ram_err;
    logic        uart_we, uart_cyc, uart_stb, uart_ack, uart_err;

    wb_addr_decoder decoder0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .we_i(wb_we), .cyc_i(wb_cyc), .stb_i(wb_stb), .ack_o(wb_ack), .err_o(wb_err),
        .ram_addr_o(ram_addr), .ram_dat_o(ram_dat_o), .ram_dat_i(ram_dat_i),
        .ram_sel_o(ram_sel), .ram_we_o(ram_we), .ram_cyc_o(ram_cyc),
        .ram_stb_o(ram_stb), .ram_ack_i(ram_ack), .ram_err_i(ram_err),
        .uart_addr_o(uart_addr), .uart_dat_o(uart_dat_o), .uart_dat_i(uart_dat_i),
        .uart_sel_o(uart_sel), .uart_we_o(uart_we), .uart_cyc_o(uart_cyc),
        .uart_stb_o(uart_stb), .uart_ack_i(uart_ack), .uart_err_i(uart_err)
    );

    wb4_sram #(.num_words(64)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(ram_addr), .dat_i(ram_dat_o), .dat_o(ram_dat_i), .sel_i(ram_sel),
        .ack_o(ram_ack), .err_o(ram_err), .cyc_i(ram_cyc), .stb_i(ram_stb), .we_i(ram_we)
    );

    uart_tx uart0 (
        .clk(clk), .rst(rst),
        .addr_i(uart_addr), .dat_i(uart_dat_o), .dat_o(uart_dat_i), .sel_i(uart_sel),
        .ack_o(uart_ack), .err_o(uart_err), .cyc_i(uart_cyc), .stb_i(uart_stb), .we_i(uart_we)
    );

    int pass_count = 0;
    int fail_count = 0;
    task automatic check(string name, logic [63:0] actual, logic [63:0] expected);
        if (actual === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    initial begin
        #1; // see header comment: run after wb4_sram's own time-0 init

        /*
         * addr  idx  instruction                    notes
         *  0x00   0  addi x1,x0,5                    x1 = 5
         *  0x04   1  addi x2,x0,10                   x2 = 10
         *  0x08   2  add  x3,x1,x2                   x3 = 15
         *  0x0C   3  addi x8,x0,0x100                x8 = data base address
         *  0x10   4  sw   x3,0(x8)                   mem[0x100] = 15
         *  0x14   5  lw   x4,0(x8)                   x4 = 15 (round trip through the real bus)
         *  0x18   6  beq  x3,x4,8      -> 0x20        taken (15==15)
         *  0x1C   7  addi x5,x0,999                  SKIPPED -- proves the taken branch really skips
         *  0x20   8  addi x6,x0,72                   x6 = 'H' (0x48)
         *  0x24   9  lui  x7,0x8                     x7 = 0x8000 (UART TX_DATA)
         *  0x28  10  sw   x6,0(x7)                   mem-mapped write -> routes to UART, prints 'H'
         *  0x2C  11  ebreak
         */
        sram0.memory[0] = {encode_i(32'sd10, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                            encode_i(32'sd5,  5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        sram0.memory[1] = {encode_i(32'sh100, 5'd0, 3'b000, 5'd8, `OPC_OP_IMM),
                            encode_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, `OPC_OP)};
        sram0.memory[2] = {encode_i(32'sd0, 5'd8, 3'b010, 5'd4, `OPC_LOAD),
                            encode_s(32'sd0, 5'd3, 5'd8, 3'b010, `OPC_STORE)};
        sram0.memory[3] = {encode_i(32'sd999, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM),
                            encode_b(32'sd8, 5'd4, 5'd3, 3'b000, `OPC_BRANCH)};
        sram0.memory[4] = {encode_u(20'h8, 5'd7, `OPC_LUI),
                            encode_i(32'sd72, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM)};
        sram0.memory[5] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},          // idx11: ebreak (0x2C)
                            encode_s(32'sd0, 5'd6, 5'd7, 3'b010, `OPC_STORE)}; // idx10: sw x6,0(x7) (0x28)

        @(posedge clk); #1;
        rst = 0;

        fork
            wait (dut.halted === 1'b1);
            begin
                repeat (150) @(posedge clk);
                $display("TIMEOUT: dut.halted never went high");
                $finish;
            end
        join_any
        #1;

        check("x1 (addi)",                     dut.regfile0.gp_registers[1], 64'd5);
        check("x2 (addi)",                     dut.regfile0.gp_registers[2], 64'd10);
        check("x3 (add)",                      dut.regfile0.gp_registers[3], 64'd15);
        check("x4 (lw, RAM round trip over bus)", dut.regfile0.gp_registers[4], 64'd15);
        check("x5 (skipped by taken beq)",     dut.regfile0.gp_registers[5], 64'd0);
        check("x6 (addi, UART payload)",       dut.regfile0.gp_registers[6], 64'd72);
        check("x7 (lui, UART base address)",   dut.regfile0.gp_registers[7], 64'h8000);
        check("x8 (addi, RAM base address)",   dut.regfile0.gp_registers[8], 64'h100);
        check("RAM contents at 0x100",         {32'b0, sram0.memory[32][31:0]}, 64'd15);
        check("UART received exactly one byte", {56'b0, uart0.tx_history_count}, 64'd1);
        check("UART byte is 'H'",              {56'b0, uart0.tx_history[0]}, 64'h48);
        check("core halted (ebreak reached)",  {63'b0, dut.halted}, 64'd1);

        $display("");
        $display("core_wb_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_wb_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
