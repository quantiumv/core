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
 *
 * ack_o/err_o/dat_o are REGISTERED -- a one-cycle-delayed echo of
 * cyc_i/stb_i/we_i, exactly matching wb4_sram.sv's own documented
 * convention (that file's own header: "a PLAIN, REGISTERED, ONE-CYCLE-
 * DELAYED ECHO"), not a free choice. An earlier version acked
 * combinationally in the same cycle as the request -- harmless on its
 * own, but lockstep_mem.sv's arbiter runs with DROP_REQ_ON_RESP=1,
 * whose own drop_req combinationally gates cyc_o on ack_i; a
 * combinational ack closes that straight back into this module's own
 * cyc_i in the same zero-time step; the simulator never leaves the
 * current time step, consuming CPU with no further output ever
 * (confirmed: firmware/hello.c -- the one real-UART-writing corpus
 * entry -- hung at exactly its first byte write to this window, and
 * nowhere else; every qvgen.py-generated test and every ACT4 ELF never
 * exercises a write here at all besides the MAGIC_CLR qvgen.py's own
 * trap handlers hit, which happened to never land in this exact window
 * before the MMIO range was widened to also cover the real UART
 * address). Registering the ack breaks the loop the same way
 * wb4_sram.sv's own slaves already do it.
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
    localparam logic [31:0] MAGIC_DWORD = `QV_LOCKSTEP_MAGIC_SET & ~32'h7;  // SET|CLR
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

    // Combinational "what THIS cycle's read would return", shared by
    // dat_o and o_rd_data below so both register the SAME next value on
    // the SAME edge -- computing o_rd_data as `<= dat_o` instead would
    // read dat_o's OLD (pre-edge) value under NBA semantics and lag one
    // extra cycle behind ack_o/dat_o themselves, desyncing the read log
    // from the data it's meant to describe.
    logic [63:0] read_result;
    always_comb begin
        read_result = 64'b0;
        if (dword_addr == MAGIC_DWORD) begin
            read_result = {magic_clr_q, magic_set_q};
        end else if (dword_addr == UART_LSR_DW) begin
            read_result = {56'b0, `QV_LOCKSTEP_UART_LSR_THRE};
        end
    end

    // Registered read data/ack/err/read-log -- see the module header for
    // why this can't be combinational. Sampled from THIS cycle's
    // access/dword_addr/we_i/addr_i, visible NEXT cycle, exactly like
    // wb4_sram.sv's own ack_o/err_o/dat_o always_ff block.
    always_ff @(posedge clk) begin
        if (rst) begin
            ack_o      <= 1'b0;
            err_o      <= 1'b0;
            dat_o      <= 64'b0;
            o_rd_valid <= 1'b0;
            o_rd_addr  <= 32'b0;
            o_rd_data  <= 64'b0;
        end else begin
            ack_o      <= access;
            err_o      <= 1'b0;
            dat_o      <= read_result;
            o_rd_valid <= access && !we_i;
            o_rd_addr  <= addr_i;
            o_rd_data  <= read_result;
        end
    end

    // Dummy UART TX: logged only, via $display, for human debugging --
    // never fed back into the simulated program.
    always_ff @(posedge clk) begin
        if (!rst && access && we_i && dword_addr == UART_THR_DW && sel_i[0]) begin
            $display("[lockstep_mmio] UART TX: %02x '%c'", dat_i[7:0],
                      (dat_i[7:0] >= 8'h20 && dat_i[7:0] < 8'h7F) ? dat_i[7:0] : "?");
        end
    end
endmodule
