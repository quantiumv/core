// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: wb_addr_decoder
 *
 * Routes the CPU's single Wishbone master port to one of three slaves --
 * design/wb4_sram.sv (RAM), design/uart_tx.sv (UART), or design/clint.sv
 * (CLINT) -- based on address. One master, three fixed slaves:
 * hand-written rather than a general N-slave interconnect, since that
 * generality isn't needed here.
 *
 * Address map, decoded off a 2-bit test ({addr_i[16], addr_i[15]}, informally):
 *   00 -> RAM   0x0000_0000-0x0000_7FFF (wb4_sram.sv's default
 *               num_words=4096 x 8 bytes/word = 32KB)
 *   01 -> UART  0x0000_8000-0x0000_FFFF (anything with bit 15 set and
 *               bit 16 clear)
 *   1x -> CLINT 0x0001_0000-0x0001_FFFF (anything with bit 16 set,
 *               REGARDLESS of bit 15 -- CLINT's window is twice the size
 *               either RAM or UART's own bit alone would carve out, since
 *               nothing currently needs the addr_i[16]==1,addr_i[15]==0
 *               vs ==1 split any further)
 *
 * The RAM/UART boundary (bit 15) is DERIVED from wb4_sram's num_words
 * parameter, not independent of it -- since RAM's size is a power of two
 * starting at address 0, "address >= 0x8000" and "bit 15 set" are the
 * same condition, a single bit test rather than a shortcut that skips a
 * real range compare. NB: if wb4_sram's default num_words ever changes,
 * this decode bit needs revisiting too. The CLINT boundary (bit 16), by
 * contrast, is a fresh, independently-chosen window -- nothing derives
 * it from any slave's own size parameter; it was simply picked to sit
 * right above the existing RAM+UART 64KB region with room to spare.
 *
 * The "remember which slave" problem: all three slaves are registered
 * (1-wait-state) Wishbone slaves, so a response arrives one cycle after
 * the request that triggered it -- by the time ack_i/dat_i actually need
 * routing back to the CPU, addr_i may already reflect a *different*,
 * newer request (or none). So which slave an outstanding transaction
 * belongs to is latched at the moment the request is issued (target_q,
 * a 2-bit enum -- generalized from the old single-bit sel_uart_q now
 * that there are three targets, not two), not re-derived from addr_i
 * when the response shows up.
 *
 * Known, accepted gap: CLINT's own window is only 3 words wide
 * (mtime/mtimecmp at CLINT_BASE+0x0/+0x8, see clint.sv) but its full
 * decoded region is 64KB (bits 17-31 of addr_i are never tested at all,
 * just like bits above RAM/UART's own windows aren't). Every address in
 * 0x0001_0000-0x0001_FFFF that isn't exactly +0x0 or +0x8 still routes
 * to clint.sv and gets a real ack (clint.sv's own addr_i[3] mux treats
 * any such address as an alias of one of its two real registers -- see
 * that module's header). No corruption risk (clint.sv has no side
 * effects beyond those two registers either way), just address aliasing
 * -- the same class of gap wb4_sram.sv's own bounds check is the only
 * thing preventing for RAM, left undocumented there too. Not worth a
 * fix without a concrete need (e.g. real device-tree/OpenSBI address
 * decoding) driving one.
 */
module wb_addr_decoder (
    input logic clk,
    input logic rst,

    // CPU-facing port -- this module is a slave from the CPU's side.
    input  logic [31:0] addr_i,
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,
    input  logic        we_i,
    input  logic        cyc_i,
    input  logic        stb_i,
    output logic        ack_o,
    output logic        err_o,

    // RAM-facing port -- this module is the master here.
    output logic [31:0] ram_addr_o,
    output logic [63:0] ram_dat_o,
    input  logic [63:0] ram_dat_i,
    output logic [7:0]  ram_sel_o,
    output logic        ram_we_o,
    output logic        ram_cyc_o,
    output logic        ram_stb_o,
    input  logic        ram_ack_i,
    input  logic        ram_err_i,

    // UART-facing port.
    output logic [31:0] uart_addr_o,
    output logic [63:0] uart_dat_o,
    input  logic [63:0] uart_dat_i,
    output logic [7:0]  uart_sel_o,
    output logic        uart_we_o,
    output logic        uart_cyc_o,
    output logic        uart_stb_o,
    input  logic        uart_ack_i,
    input  logic        uart_err_i,

    // CLINT-facing port.
    output logic [31:0] clint_addr_o,
    output logic [63:0] clint_dat_o,
    input  logic [63:0] clint_dat_i,
    output logic [7:0]  clint_sel_o,
    output logic        clint_we_o,
    output logic        clint_cyc_o,
    output logic        clint_stb_o,
    input  logic        clint_ack_i,
    input  logic        clint_err_i
);
    wire sel_clint = addr_i[16];
    wire sel_uart  = !addr_i[16] && addr_i[15];

    /*
     * Gate cyc/stb per slave; broadcast everything else (addr/dat/sel/we)
     * to all three -- harmless, since a slave with cyc=0 ignores the rest
     * of the bus regardless of what's sitting on it.
     */
    assign ram_cyc_o   = cyc_i && !sel_uart && !sel_clint;
    assign ram_stb_o   = stb_i && !sel_uart && !sel_clint;
    assign uart_cyc_o  = cyc_i && sel_uart;
    assign uart_stb_o  = stb_i && sel_uart;
    assign clint_cyc_o = cyc_i && sel_clint;
    assign clint_stb_o = stb_i && sel_clint;

    assign ram_addr_o   = addr_i;
    assign uart_addr_o  = addr_i;
    assign clint_addr_o = addr_i;
    assign ram_dat_o    = dat_i;
    assign uart_dat_o   = dat_i;
    assign clint_dat_o  = dat_i;
    assign ram_sel_o    = sel_i;
    assign uart_sel_o   = sel_i;
    assign clint_sel_o  = sel_i;
    assign ram_we_o     = we_i;
    assign uart_we_o    = we_i;
    assign clint_we_o   = we_i;

    /*
     * Latched at the cycle a request is actually issued (cyc_i && stb_i),
     * held until the next request overwrites it -- see the module header
     * for why this can't just re-check addr_i when the response arrives.
     * Generalized from the old 1-bit sel_uart_q to a 2-bit enum now that
     * there are three possible targets, not two.
     */
    typedef enum logic [1:0] { TARGET_RAM, TARGET_UART, TARGET_CLINT } target_t;

    target_t target;
    always_comb begin
        if (sel_clint)      target = TARGET_CLINT;
        else if (sel_uart)  target = TARGET_UART;
        else                target = TARGET_RAM;
    end

    target_t target_q;
    always_ff @(posedge clk) begin
        if (rst)
            target_q <= TARGET_RAM;
        else if (cyc_i && stb_i)
            target_q <= target;
    end

    always_comb begin
        case (target_q)
            TARGET_UART:  begin ack_o = uart_ack_i;  err_o = uart_err_i;  dat_o = uart_dat_i;  end
            TARGET_CLINT: begin ack_o = clint_ack_i; err_o = clint_err_i; dat_o = clint_dat_i; end
            default:      begin ack_o = ram_ack_i;   err_o = ram_err_i;   dat_o = ram_dat_i;   end
        endcase
    end
endmodule
