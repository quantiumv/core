/*
 * lockstep_mmio.sv -- the P3.4 lockstep harness's own MMIO device: the
 * MAGIC interrupt set/clear registers qvgen.py's trap handlers already
 * assume exist (gen/qvgen.py:608, 718 write a literal 1 to 0x0400F004 to
 * clear an injected interrupt), plus a dummy UART so a stray probe never
 * bus-faults the sim (LSR reads always report THRE/TEMT; THR writes are
 * only ever logged, never actually transmitted anywhere) -- including
 * from a program written against the REAL soc.sv memory map rather than
 * qvgen.py's, e.g. firmware/hello.c, which writes its output character
 * straight to 0x04008000 (the real 16550's THR at offset 0) and expects
 * that write to just work, not fault.
 *
 * A single Wishbone B4 classic slave port, zero wait states, spanning
 * lockstep_defs.svh's whole (deliberately wide) MMIO window. Any address
 * in that window besides the specific registers below is a harmless
 * dummy for free: ack_o is unconditional, err_o is always 0, a write to
 * anything unrecognized simply updates no state, and a read of anything
 * unrecognized returns 0 -- so a stray probe from EITHER memory-map
 * convention this window has to serve never bus-faults here. The caller
 * (lockstep_mem.sv) is responsible for only asserting cyc_i/stb_i when
 * the address actually falls in this device's window.
 */
`include "lockstep_defs.svh"

module lockstep_mmio (
    input  logic        clk,
    input  logic        rst,

    input  logic [31:0] addr_i,
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,
    input  logic        we_i,
    input  logic        cyc_i,
    input  logic        stb_i,
    output logic        ack_o,
    output logic        err_o,

    // software-visible MAGIC writes, RVFI-observed by lockstep_irq.sv
    output logic        o_magic_set_we,
    output logic [31:0] o_magic_set_wdata,
    output logic        o_magic_clr_we,
    output logic [31:0] o_magic_clr_wdata,

    // ordered MMIO-read log, consumed by lockstep_rec.sv
    output logic        o_rd_valid,
    output logic [31:0] o_rd_addr,
    output logic [63:0] o_rd_data
);
    localparam logic [31:0] MAGIC_DWORD = `QV_LOCKSTEP_MMIO_BASE;          // SET|CLR
    localparam logic [31:0] UART_THR_DW = `QV_LOCKSTEP_UART_THR & ~32'h7;
    localparam logic [31:0] UART_LSR_DW = `QV_LOCKSTEP_UART_LSR & ~32'h7;

    wire         access    = cyc_i && stb_i;
    wire [31:0]  dword_addr = {addr_i[31:3], 3'b0};

    logic [31:0] magic_set_q, magic_clr_q;

    always_ff @(posedge clk) begin
        o_magic_set_we <= 1'b0;
        o_magic_clr_we <= 1'b0;
        if (rst) begin
            magic_set_q <= '0;
            magic_clr_q <= '0;
        end else if (access && we_i && dword_addr == MAGIC_DWORD) begin
            // SET occupies byte lanes [3:0] of this dword, CLR occupies
            // [7:4] -- matches how a 32-bit `sw` to the +4 offset lands on
            // a 64-bit Wishbone data bus (see wb4_sram.sv's own convention).
            if (sel_i[3:0] != 4'b0) begin
                magic_set_q       <= dat_i[31:0];
                o_magic_set_we    <= 1'b1;
                o_magic_set_wdata <= dat_i[31:0];
            end
            if (sel_i[7:4] != 4'b0) begin
                magic_clr_q       <= dat_i[63:32];
                o_magic_clr_we    <= 1'b1;
                o_magic_clr_wdata <= dat_i[63:32];
            end
        end
    end

    always_comb begin
        dat_o = 64'b0;
        if (dword_addr == MAGIC_DWORD) begin
            dat_o = {magic_clr_q, magic_set_q};
        end else if (dword_addr == UART_LSR_DW) begin
            dat_o = {56'b0, `QV_LOCKSTEP_UART_LSR_THRE};
        end
    end

    assign ack_o = access;
    assign err_o = 1'b0;

    assign o_rd_valid = access && !we_i;
    assign o_rd_addr  = addr_i;
    assign o_rd_data  = dat_o;

    // Dummy UART TX: logged only, via $display, for human debugging --
    // never fed back into the simulated program.
    always_ff @(posedge clk) begin
        if (!rst && access && we_i && dword_addr == UART_THR_DW && sel_i[0]) begin
            $display("[lockstep_mmio] UART TX: %02x '%c'", dat_i[7:0],
                      (dat_i[7:0] >= 8'h20 && dat_i[7:0] < 8'h7F) ? dat_i[7:0] : "?");
        end
    end
endmodule
