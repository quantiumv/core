// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: soc, UART RX end-to-end through the real decoder/soc.sv
 * addr_i[4] sub-decode
 *
 * Unlike design/uart_rx_tb.sv (drives uart_rx's own Wishbone port
 * directly, in isolation), this instantiates the real top-level
 * design/soc.sv and runs real firmware through core0, proving the new
 * addr_i[4] TX/RX split introduced in soc.sv (see that file's header)
 * is wired correctly end-to-end -- a real load instruction to 0x8010/
 * 0x8018 must actually reach uart_rx0, not uart0, and a real store to
 * 0x8000 must still reach uart0 unperturbed. Bytes are injected via
 * uart_rx0's push_byte backdoor (dut.uart_rx0.push_byte), the same
 * mechanism design/uart_rx_tb.sv uses, just reached one level deeper
 * through soc.sv's hierarchy.
 *
 * Instructions are packed two-per-64-bit-word directly into the SRAM's
 * memory[] array, same convention as testbench/core_wb_tb.sv (see that
 * file's own header for the full addressing rationale).
 */
module soc_uart_rx_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    soc dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    logic halted = 1'b0;
    always @(posedge clk) if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"

    initial begin
        #1; // see core_wb_tb.sv's header: run after wb4_sram's own time-0 init

        /*
         * addr  idx  instruction                    notes
         *  0x00   0  lui  x8,0x8                     x8 = 0x8000
         *  0x04   1  addi x8,x8,0x10                 x8 = 0x8010 (RX_DATA)
         *  0x08   2  lui  x9,0x8                     x9 = 0x8000
         *  0x0C   3  addi x9,x9,0x18                 x9 = 0x8018 (RX_STATUS)
         *  0x10   4  lui  x10,0x8                    x10 = 0x8000 (TX_DATA)
         *  0x14   5  lw   x4,0(x9)                   x4 = RX_STATUS before drain (expect 1)
         *  0x18   6  lw   x1,0(x8)                   x1 = RX_DATA pop 1 (expect 'A')
         *  0x1C   7  lw   x2,0(x8)                   x2 = RX_DATA pop 2 (expect 'B')
         *  0x20   8  lw   x3,0(x8)                   x3 = RX_DATA pop 3 (expect 'C')
         *  0x24   9  lw   x5,0(x9)                   x5 = RX_STATUS after drain (expect 0)
         *  0x28  10  addi x6,x0,72                   x6 = 'H' (0x48)
         *  0x2C  11  sw   x6,0(x10)                  TX_DATA <- 'H' -- proves TX still works
         *  0x30  12  lw   x11,8(x10)                 x11 = TX_STATUS (0x8008) through the real
         *                                             soc.sv mux -- proves the uart_tx_ack-true
         *                                             arm of uart_dat_i's mux, never otherwise
         *                                             exercised by a bus-level load in this suite
         *  0x34  13  ebreak
         */
        dut.sram0.memory[0] = {encode_i(32'sh10, 5'd8, 3'b000, 5'd8, `OPC_OP_IMM),
                                encode_u(20'h8, 5'd8, `OPC_LUI)};
        dut.sram0.memory[1] = {encode_i(32'sh18, 5'd9, 3'b000, 5'd9, `OPC_OP_IMM),
                                encode_u(20'h8, 5'd9, `OPC_LUI)};
        dut.sram0.memory[2] = {encode_i(32'sd0, 5'd9, 3'b010, 5'd4, `OPC_LOAD),
                                encode_u(20'h8, 5'd10, `OPC_LUI)};
        dut.sram0.memory[3] = {encode_i(32'sd0, 5'd8, 3'b010, 5'd2, `OPC_LOAD),
                                encode_i(32'sd0, 5'd8, 3'b010, 5'd1, `OPC_LOAD)};
        dut.sram0.memory[4] = {encode_i(32'sd0, 5'd9, 3'b010, 5'd5, `OPC_LOAD),
                                encode_i(32'sd0, 5'd8, 3'b010, 5'd3, `OPC_LOAD)};
        dut.sram0.memory[5] = {encode_s(32'sd0, 5'd6, 5'd10, 3'b010, `OPC_STORE),
                                encode_i(32'sd72, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM)};
        dut.sram0.memory[6] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                          // idx13: ebreak (0x34)
                                encode_i(32'sd8, 5'd10, 3'b010, 5'd11, `OPC_LOAD)};         // idx12: lw x11,8(x10) (0x30)

        @(posedge clk); #1;
        rst = 0;

        /*
         * Pushed right as reset drops -- uart_rx0's own reset clears
         * rx_head/rx_tail/rx_count, so pushing any earlier would be
         * silently wiped. This lands well before core0's first real bus
         * transaction (the fetch of the instruction at pc=0) completes,
         * so it's deterministically visible by the time the program's
         * own RX_STATUS/RX_DATA reads execute.
         */
        dut.uart_rx0.push_byte(8'h41); // 'A'
        dut.uart_rx0.push_byte(8'h42); // 'B'
        dut.uart_rx0.push_byte(8'h43); // 'C'

        wait_halted_or_timeout(`TIMEOUT_CYCLES_TINY, "EBREAK trap never fired");

        check("x8 (RX_DATA address)",              dut.core0.regfile0.gp_registers[8],  64'h8010);
        check("x9 (RX_STATUS address)",             dut.core0.regfile0.gp_registers[9],  64'h8018);
        check("x10 (TX_DATA address)",              dut.core0.regfile0.gp_registers[10], 64'h8000);
        check("x4 (RX_STATUS before drain, ready)", dut.core0.regfile0.gp_registers[4],  64'd1);
        check("x1 (RX_DATA pop 1, real bus route to uart_rx0)", dut.core0.regfile0.gp_registers[1], 64'h41);
        check("x2 (RX_DATA pop 2)",                 dut.core0.regfile0.gp_registers[2],  64'h42);
        check("x3 (RX_DATA pop 3)",                 dut.core0.regfile0.gp_registers[3],  64'h43);
        check("x5 (RX_STATUS after drain, empty)",  dut.core0.regfile0.gp_registers[5],  64'd0);
        check("uart_rx0 queue fully drained",       {55'b0, dut.uart_rx0.rx_count},       64'd0);
        check("TX still routes to uart0, unperturbed by RX traffic",
              {55'b0, dut.uart0.tx_history_count}, 64'd1);
        check("TX byte is 'H'", {56'b0, dut.uart0.tx_history[0]}, 64'h48);
        check("x11 (TX_STATUS read through the real soc.sv mux, proves uart_tx_ack-true arm)",
              dut.core0.regfile0.gp_registers[11], 64'd1);
        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("soc_uart_rx_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("soc_uart_rx_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
