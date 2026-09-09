// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: soc, UART RX end-to-end through the real decoder/soc.sv
 * path and the real design/uart16550.sv register file
 *
 * Unlike design/uart16550_tb.sv (drives uart16550's own Wishbone port
 * directly, in isolation), this instantiates the real top-level
 * design/soc.sv and runs real firmware through core0, proving RBR/LSR/
 * IIR/THR all land correctly at the real uart0 instance through the
 * real decoder -- no soc.sv-level address decode exists any more for
 * UART (the old addr_i[4] TX/RX split retired with uart_tx.sv/
 * uart_rx.sv, see soc.sv's own header); this program is REWRITTEN
 * against uart16550.sv's own packed-byte-lane register file (see that
 * module's own header), not just patched at the old offsets, since a
 * real LB/LBU/SB access is now required (a wider LW/SW would span
 * multiple distinct registers at once -- see uart16550.sv's header).
 * Bytes are injected via uart0's push_byte backdoor (dut.uart0.push_byte
 * -- the CLINT/UART standards-compliance plan's own uart0/uart_rx0
 * rename, since a single instance now owns both directions), the same
 * mechanism design/uart16550_tb.sv uses, just reached one level deeper
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
         *  0x00   0  lui  x8,0x4008                  x8 = 0x04008000 (UART_BASE, RBR/THR)
         *  0x04   1  addi x9,x8,5                    x9 = 0x04008005 (LSR)
         *  0x08   2  lbu  x4,0(x9)                    x4 = LSR raw before drain
         *  0x0C   3  andi x4,x4,1                     x4 = LSR.DR isolated (expect 1)
         *  0x10   4  lbu  x1,0(x8)                    x1 = RBR pop 1 (expect 'A')
         *  0x14   5  lbu  x2,0(x8)                    x2 = RBR pop 2 (expect 'B')
         *  0x18   6  lbu  x3,0(x8)                    x3 = RBR pop 3 (expect 'C')
         *  0x1C   7  lbu  x5,0(x9)                    x5 = LSR raw after drain
         *  0x20   8  andi x5,x5,1                     x5 = LSR.DR isolated (expect 0)
         *  0x24   9  addi x6,x0,72                    x6 = 'H' (0x48)
         *  0x28  10  sb   x6,0(x8)                    THR <- 'H' -- proves TX still works,
         *                                              through the real uart0 instance, no mux
         *  0x2C  11  addi x11,x8,2                    x11 = 0x04008002 (IIR)
         *  0x30  12  lbu  x12,0(x11)                  x12 = IIR (expect 1, no ints armed/pending)
         *  0x34  13  ebreak
         *
         * Byte-width loads/stores are REQUIRED here, not a style choice
         * -- see this file's own header and design/uart16550.sv's own
         * header for why a wider access would span multiple registers.
         */
        dut.sram0.memory[0] = {encode_i(32'sd5, 5'd8, 3'b000, 5'd9, `OPC_OP_IMM),   // idx1: addi x9,x8,5 (0x04)
                                encode_u(20'h4008, 5'd8, `OPC_LUI)};                 // idx0: lui x8,0x4008 (0x00)
        dut.sram0.memory[1] = {encode_i(32'sd1, 5'd4, 3'b111, 5'd4, `OPC_OP_IMM),   // idx3: andi x4,x4,1 (0x0C)
                                encode_i(32'sd0, 5'd9, 3'b100, 5'd4, `OPC_LOAD)};    // idx2: lbu x4,0(x9) (0x08)
        dut.sram0.memory[2] = {encode_i(32'sd0, 5'd8, 3'b100, 5'd2, `OPC_LOAD),     // idx5: lbu x2,0(x8) (0x14)
                                encode_i(32'sd0, 5'd8, 3'b100, 5'd1, `OPC_LOAD)};    // idx4: lbu x1,0(x8) (0x10)
        dut.sram0.memory[3] = {encode_i(32'sd0, 5'd9, 3'b100, 5'd5, `OPC_LOAD),     // idx7: lbu x5,0(x9) (0x1C)
                                encode_i(32'sd0, 5'd8, 3'b100, 5'd3, `OPC_LOAD)};    // idx6: lbu x3,0(x8) (0x18)
        dut.sram0.memory[4] = {encode_i(32'sd72, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM),  // idx9: addi x6,x0,72 (0x24)
                                encode_i(32'sd1, 5'd5, 3'b111, 5'd5, `OPC_OP_IMM)};  // idx8: andi x5,x5,1 (0x20)
        dut.sram0.memory[5] = {encode_i(32'sd2, 5'd8, 3'b000, 5'd11, `OPC_OP_IMM),  // idx11: addi x11,x8,2 (0x2C)
                                encode_s(32'sd0, 5'd6, 5'd8, 3'b000, `OPC_STORE)};   // idx10: sb x6,0(x8) (0x28)
        dut.sram0.memory[6] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                          // idx13: ebreak (0x34)
                                encode_i(32'sd0, 5'd11, 3'b100, 5'd12, `OPC_LOAD)};         // idx12: lbu x12,0(x11) (0x30)

        @(posedge clk); #1;
        rst = 0;

        /*
         * Pushed right as reset drops -- uart0's own reset clears
         * rx_head/rx_tail/rx_count, so pushing any earlier would be
         * silently wiped. This lands well before core0's first real bus
         * transaction (the fetch of the instruction at pc=0) completes,
         * so it's deterministically visible by the time the program's
         * own LSR/RBR reads execute.
         */
        dut.uart0.push_byte(8'h41); // 'A'
        dut.uart0.push_byte(8'h42); // 'B'
        dut.uart0.push_byte(8'h43); // 'C'

        wait_halted_or_timeout(`TIMEOUT_CYCLES_TINY, "EBREAK trap never fired");

        check("x8 (UART_BASE, RBR/THR address)",    dut.core0.regfile0.gp_registers[8],  64'h04008000);
        check("x9 (LSR address)",                   dut.core0.regfile0.gp_registers[9],  64'h04008005);
        check("x4 (LSR.DR before drain, ready)",     dut.core0.regfile0.gp_registers[4],  64'd1);
        check("x1 (RBR pop 1, real bus route to uart0)", dut.core0.regfile0.gp_registers[1], 64'h41);
        check("x2 (RBR pop 2)",                      dut.core0.regfile0.gp_registers[2],  64'h42);
        check("x3 (RBR pop 3)",                      dut.core0.regfile0.gp_registers[3],  64'h43);
        check("x5 (LSR.DR after drain, empty)",      dut.core0.regfile0.gp_registers[5],  64'd0);
        check("uart0 RX queue fully drained",        {55'b0, dut.uart0.rx_count},          64'd0);
        check("TX still routes to uart0, unperturbed by RX traffic",
              {55'b0, dut.uart0.tx_history_count}, 64'd1);
        check("TX byte is 'H'", {56'b0, dut.uart0.tx_history[0]}, 64'h48);
        check("x11 (IIR address)", dut.core0.regfile0.gp_registers[11], 64'h04008002);
        check("x12 (IIR reads 'none pending', 0x01 -- IER never armed in this test)",
              dut.core0.regfile0.gp_registers[12], 64'h01);
        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("soc_uart_rx_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("soc_uart_rx_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
