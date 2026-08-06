// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core (Wishbone-master FSM) against real bus slaves, via soc
 *
 * Unlike the five core_*_tb.sv testbenches from the single-cycle
 * milestone (which still compile and pass against this core.sv, poking
 * their programs directly into a real wb4_sram instance instead of the
 * private imem0 they were originally written against), this exercises
 * exactly what's NEW in the FSM rewrite: multi-cycle fetch,
 * multi-cycle load/store, and routing through a real wb_addr_decoder to
 * two real slaves (wb4_sram, uart_tx). It deliberately does NOT re-prove
 * individual ALU ops, branch types, or the *W op family -- that datapath logic is
 * unchanged from the single-cycle version and was already proven there.
 *
 * Instantiates design/soc.sv directly rather than hand-wiring the same
 * four modules a second time -- this file's own wiring used to be
 * byte-identical to soc.sv's body (soc.sv was originally extracted from
 * it), so `soc dut (...)` below is the same circuit, not a new one. One
 * side effect: sram0 now sizes at soc.sv's real 4096-word default rather
 * than this file's old deliberately-small 64-word override -- harmless,
 * since wb_addr_decoder's RAM/UART split is a fixed address-bit test
 * (addr_i[15]), independent of wb4_sram's num_words.
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

    soc dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    wire halted = dut.core0.halted;
    `include "halt_wait.sv"

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
        dut.sram0.memory[0] = {encode_i(32'sd10, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                            encode_i(32'sd5,  5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut.sram0.memory[1] = {encode_i(32'sh100, 5'd0, 3'b000, 5'd8, `OPC_OP_IMM),
                            encode_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, `OPC_OP)};
        dut.sram0.memory[2] = {encode_i(32'sd0, 5'd8, 3'b010, 5'd4, `OPC_LOAD),
                            encode_s(32'sd0, 5'd3, 5'd8, 3'b010, `OPC_STORE)};
        dut.sram0.memory[3] = {encode_i(32'sd999, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM),
                            encode_b(32'sd8, 5'd4, 5'd3, 3'b000, `OPC_BRANCH)};
        dut.sram0.memory[4] = {encode_u(20'h8, 5'd7, `OPC_LUI),
                            encode_i(32'sd72, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM)};
        dut.sram0.memory[5] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},          // idx11: ebreak (0x2C)
                            encode_s(32'sd0, 5'd6, 5'd7, 3'b010, `OPC_STORE)}; // idx10: sw x6,0(x7) (0x28)

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_TINY, "dut.core0.halted never went high");

        check("x1 (addi)",                     dut.core0.regfile0.gp_registers[1], 64'd5);
        check("x2 (addi)",                     dut.core0.regfile0.gp_registers[2], 64'd10);
        check("x3 (add)",                      dut.core0.regfile0.gp_registers[3], 64'd15);
        check("x4 (lw, RAM round trip over bus)", dut.core0.regfile0.gp_registers[4], 64'd15);
        check("x5 (skipped by taken beq)",     dut.core0.regfile0.gp_registers[5], 64'd0);
        check("x6 (addi, UART payload)",       dut.core0.regfile0.gp_registers[6], 64'd72);
        check("x7 (lui, UART base address)",   dut.core0.regfile0.gp_registers[7], 64'h8000);
        check("x8 (addi, RAM base address)",   dut.core0.regfile0.gp_registers[8], 64'h100);
        check("RAM contents at 0x100",         {32'b0, dut.sram0.memory[32][31:0]}, 64'd15);
        check("UART received exactly one byte", {55'b0, dut.uart0.tx_history_count}, 64'd1);
        check("UART byte is 'H'",              {56'b0, dut.uart0.tx_history[0]}, 64'h48);
        check("core halted (ebreak reached)",  {63'b0, dut.core0.halted}, 64'd1);

        $display("");
        $display("core_wb_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_wb_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
