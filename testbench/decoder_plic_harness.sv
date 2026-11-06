// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: decoder_plic_harness
 *
 * Shared "decoder + real slaves, no core" wiring -- extends
 * decoder_clint_harness.sv (this file's own direct template) with a
 * real plic0 instance on the decoder's new fifth slave port
 * (PMP+PLIC plan Milestone 5). Same scope note as that file: this is a
 * bus-level test fixture (raw Wishbone cycles via wb_driver.sv's
 * wb_cycle()), not a firmware/instruction-level one -- RAM's leg omits
 * soc.sv's own cache_complex, exactly like decoder_clint_harness.sv.
 *
 * i_uart_rx_irq is re-exposed as a top-level port (unlike soc.sv's own
 * decoder0, which ties it to a constant 1'b0 this same milestone) so a
 * test here COULD exercise it if useful -- this harness's own real job
 * is address-decode fidelity, not re-proving plic.sv's internal gateway
 * semantics (design/plic_tb.sv already does that in full), so most
 * tests are expected to leave it low.
 */
module decoder_plic_harness (
    input logic clk,
    input logic rst,

    input  logic [31:0] addr_i,
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,
    input  logic        we_i,
    input  logic        cyc_i,
    input  logic        stb_i,
    output logic        ack_o,
    output logic        err_o,

    input  logic i_uart_rx_irq
);

    logic [31:0] ram_addr, uart_addr, clint_addr, plic_addr;
    logic [63:0] ram_dat_o, ram_dat_i, uart_dat_o, uart_dat_i, clint_dat_o, clint_dat_i, plic_dat_o, plic_dat_i;
    logic [7:0]  ram_sel, uart_sel, clint_sel, plic_sel;
    logic        ram_we, ram_cyc, ram_stb, ram_ack, ram_err;
    logic        uart_we, uart_cyc, uart_stb, uart_ack, uart_err;
    logic        clint_we, clint_cyc, clint_stb, clint_ack, clint_err;
    logic        plic_we, plic_cyc, plic_stb, plic_ack, plic_err;

    // See decoder0's own dram_* port comment below for the full reasoning.
    logic dram_stub_cyc, dram_stub_stb;
    logic dram_stub_err_q;

    wb_addr_decoder decoder0 (
        .clk(clk), .rst(rst),
        .addr_i(addr_i), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel_i),
        .we_i(we_i), .cyc_i(cyc_i), .stb_i(stb_i), .ack_o(ack_o), .err_o(err_o),
        .ram_addr_o(ram_addr), .ram_dat_o(ram_dat_o), .ram_dat_i(ram_dat_i),
        .ram_sel_o(ram_sel), .ram_we_o(ram_we), .ram_cyc_o(ram_cyc),
        .ram_stb_o(ram_stb), .ram_ack_i(ram_ack), .ram_err_i(ram_err),
        .uart_addr_o(uart_addr), .uart_dat_o(uart_dat_o), .uart_dat_i(uart_dat_i),
        .uart_sel_o(uart_sel), .uart_we_o(uart_we), .uart_cyc_o(uart_cyc),
        .uart_stb_o(uart_stb), .uart_ack_i(uart_ack), .uart_err_i(uart_err),
        .clint_addr_o(clint_addr), .clint_dat_o(clint_dat_o), .clint_dat_i(clint_dat_i),
        .clint_sel_o(clint_sel), .clint_we_o(clint_we), .clint_cyc_o(clint_cyc),
        .clint_stb_o(clint_stb), .clint_ack_i(clint_ack), .clint_err_i(clint_err),
        .plic_addr_o(plic_addr), .plic_dat_o(plic_dat_o), .plic_dat_i(plic_dat_i),
        .plic_sel_o(plic_sel), .plic_we_o(plic_we), .plic_cyc_o(plic_cyc),
        .plic_stb_o(plic_stb), .plic_ack_i(plic_ack), .plic_err_i(plic_err),

        /*
         * dram_* left explicitly unconnected/stubbed -- same situation
         * and same reasoning as decoder_clint_harness.sv's own decoder0
         * instantiation (DRAM's own slave is Verilator-only; this
         * harness is compiled via iverilog).
         */
        /* verilator lint_off PINCONNECTEMPTY */
        .dram_addr_o(), .dram_dat_o(), .dram_sel_o(), .dram_we_o(),
        /* verilator lint_on PINCONNECTEMPTY */
        .dram_cyc_o(dram_stub_cyc), .dram_stb_o(dram_stub_stb),
        .dram_dat_i('0), .dram_ack_i(1'b0), .dram_err_i(dram_stub_err_q)
    );

    always_ff @(posedge clk) begin
        if (rst) dram_stub_err_q <= 1'b0;
        else     dram_stub_err_q <= dram_stub_cyc && dram_stub_stb;
    end

    wb4_sram #(.num_words(4096)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(ram_addr), .dat_i(ram_dat_o), .dat_o(ram_dat_i), .sel_i(ram_sel),
        .ack_o(ram_ack), .err_o(ram_err), .cyc_i(ram_cyc), .stb_i(ram_stb), .we_i(ram_we)
    );

    uart16550 uart0 (
        .clk(clk), .rst(rst),
        .addr_i(uart_addr), .dat_i(uart_dat_o), .dat_o(uart_dat_i), .sel_i(uart_sel),
        .ack_o(uart_ack), .err_o(uart_err), .cyc_i(uart_cyc), .stb_i(uart_stb), .we_i(uart_we),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_irq()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    clint clint0 (
        .clk(clk), .rst(rst),
        .addr_i(clint_addr), .dat_i(clint_dat_o), .dat_o(clint_dat_i), .sel_i(clint_sel),
        .ack_o(clint_ack), .err_o(clint_err), .cyc_i(clint_cyc), .stb_i(clint_stb), .we_i(clint_we),
        .mtip_o()
    );

    plic plic0 (
        .clk(clk), .rst(rst),
        .addr_i(plic_addr), .dat_i(plic_dat_o), .dat_o(plic_dat_i), .sel_i(plic_sel),
        .ack_o(plic_ack), .err_o(plic_err), .cyc_i(plic_cyc), .stb_i(plic_stb), .we_i(plic_we),
        .i_uart_rx_irq(i_uart_rx_irq), .o_meip(), .o_seip()
    );

endmodule
