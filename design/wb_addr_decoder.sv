// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: wb_addr_decoder
 *
 * Routes the CPU's single Wishbone master port to one of four slaves --
 * design/wb4_sram.sv (RAM), design/uart_tx.sv (UART), design/clint.sv
 * (CLINT), or verification/taxi/rtl/dram_model.sv (DRAM) -- based on
 * address. One master, four fixed slaves: hand-written rather than a
 * general N-slave interconnect, since that generality isn't needed here.
 *
 * Address map, decoded off a real 2-bit test ({addr_i[16], addr_i[15]}):
 *   00 -> RAM   0x0000_0000-0x0000_7FFF (wb4_sram.sv's default
 *               num_words=4096 x 8 bytes/word = 32KB)
 *   01 -> UART  0x0000_8000-0x0000_FFFF
 *   10 -> CLINT 0x0001_0000-0x0001_7FFF (32KB -- narrowed from an
 *               earlier 64KB window that claimed both addr_i[15] values;
 *               see "Known, accepted gap" below for why 32KB still isn't
 *               tight against CLINT's own real register footprint)
 *   11 -> DRAM  0x0001_8000-0x0001_FFFF (32KB, the window CLINT's own
 *               narrowing freed up -- see "DRAM address translation"
 *               below for why dram_addr_o needs special handling)
 *
 * The RAM/UART boundary (bit 15) is DERIVED from wb4_sram's num_words
 * parameter, not independent of it -- since RAM's size is a power of two
 * starting at address 0, "address >= 0x8000" and "bit 15 set" are the
 * same condition, a single bit test rather than a shortcut that skips a
 * real range compare. NB: if wb4_sram's default num_words ever changes,
 * this decode bit needs revisiting too. The CLINT/DRAM boundary (bit 16),
 * by contrast, is a fresh, independently-chosen window -- nothing derives
 * it from any slave's own size parameter; it was simply picked to sit
 * right above the existing RAM+UART 64KB region with room to spare.
 *
 * The "remember which slave" problem: all four slaves are registered
 * (1-wait-state-or-more) Wishbone slaves, so a response arrives one or
 * more cycles after the request that triggered it -- by the time
 * ack_i/dat_i actually need routing back to the CPU, addr_i may already
 * reflect a *different*, newer request (or none). So which slave an
 * outstanding transaction belongs to is latched at the moment the
 * request is issued (target_q, a 2-bit enum -- now fully saturated with
 * four real targets, no spare encoding left), not re-derived from addr_i
 * when the response shows up.
 *
 * Known, accepted gap: CLINT's own window is only 3 words wide
 * (mtime/mtimecmp at CLINT_BASE+0x0/+0x8, see clint.sv) but its decoded
 * region is 32KB (bits 17-31 of addr_i are never tested at all, just
 * like bits above RAM/UART/DRAM's own windows aren't). Every address in
 * 0x0001_0000-0x0001_7FFF that isn't exactly +0x0 or +0x8 still routes
 * to clint.sv and gets a real ack (clint.sv's own addr_i[3] mux treats
 * any such address as an alias of one of its two real registers -- see
 * that module's header). No corruption risk (clint.sv has no side
 * effects beyond those two registers either way), just address aliasing
 * -- the same class of gap wb4_sram.sv's own bounds check is the only
 * thing preventing for RAM, left undocumented there too. Not worth a
 * fix without a concrete need (e.g. real device-tree/OpenSBI address
 * decoding) driving one.
 *
 * DRAM address translation -- the one deliberate exception among the
 * four *_addr_o broadcast assigns below: ram_addr_o/uart_addr_o/
 * clint_addr_o all pass addr_i straight through UNTRANSLATED, and that's
 * only ever safe by coincidence -- RAM's window happens to sit at system
 * address 0 (so "raw" and "window-local" addresses are identical), and
 * uart_tx.sv/clint.sv do NO bounds check of their own at all (they rely
 * entirely on THIS module's cyc/stb gating and never look at their own
 * addr_i's upper bits). dram_model.sv is neither of those: it does a
 * real, self-contained bounds check against a ZERO-BASED window
 * (`addr_valid = (addr_i[31:ADDR_W] == '0)`, see that file). Handing it
 * the raw system address (nonzero bits 15/16 for every legitimately-
 * routed DRAM address) would fail that check on every single access,
 * permanently and silently breaking DRAM with err_o instead of ack_o --
 * so dram_addr_o is rebased to a window-local address instead
 * (`{17'b0, addr_i[14:0]}`), the one broadcast assign that isn't a bare
 * passthrough.
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
    input  logic        clint_err_i,

    // DRAM-facing port.
    output logic [31:0] dram_addr_o,
    output logic [63:0] dram_dat_o,
    input  logic [63:0] dram_dat_i,
    output logic [7:0]  dram_sel_o,
    output logic        dram_we_o,
    output logic        dram_cyc_o,
    output logic        dram_stb_o,
    input  logic        dram_ack_i,
    input  logic        dram_err_i
);
    wire sel_ram   = !addr_i[16] && !addr_i[15];
    wire sel_uart  = !addr_i[16] &&  addr_i[15];
    wire sel_clint =  addr_i[16] && !addr_i[15];
    wire sel_dram  =  addr_i[16] &&  addr_i[15];

    /*
     * Gate cyc/stb per slave; broadcast everything else (addr/dat/sel/we)
     * to all four -- harmless, since a slave with cyc=0 ignores the rest
     * of the bus regardless of what's sitting on it.
     */
    assign ram_cyc_o   = cyc_i && sel_ram;
    assign ram_stb_o   = stb_i && sel_ram;
    assign uart_cyc_o  = cyc_i && sel_uart;
    assign uart_stb_o  = stb_i && sel_uart;
    assign clint_cyc_o = cyc_i && sel_clint;
    assign clint_stb_o = stb_i && sel_clint;
    assign dram_cyc_o  = cyc_i && sel_dram;
    assign dram_stb_o  = stb_i && sel_dram;

    assign ram_addr_o   = addr_i;
    assign uart_addr_o  = addr_i;
    assign clint_addr_o = addr_i;
    assign dram_addr_o  = {17'b0, addr_i[14:0]}; // rebased -- see "DRAM address
                                                  // translation" in the header.
    assign ram_dat_o    = dat_i;
    assign uart_dat_o   = dat_i;
    assign clint_dat_o  = dat_i;
    assign dram_dat_o   = dat_i;
    assign ram_sel_o    = sel_i;
    assign uart_sel_o   = sel_i;
    assign clint_sel_o  = sel_i;
    assign dram_sel_o   = sel_i;
    assign ram_we_o     = we_i;
    assign uart_we_o    = we_i;
    assign clint_we_o   = we_i;
    assign dram_we_o    = we_i;

    /*
     * Latched at the cycle a request is actually issued (cyc_i && stb_i),
     * held until the next request overwrites it -- see the module header
     * for why this can't just re-check addr_i when the response arrives.
     * A 2-bit enum, now fully saturated with four real targets (no spare
     * encoding left, unlike the old 3-target version).
     */
    typedef enum logic [1:0] { TARGET_RAM, TARGET_UART, TARGET_CLINT, TARGET_DRAM } target_t;

    // RAM stays the terminal `else` here (equivalent to sel_ram by
    // construction, since the 4-way decode above is exhaustive) rather
    // than an explicit `if (sel_ram)` arm -- matches this file's existing
    // defensive-catch-all style (mirrored below in the read-mux `default:`).
    target_t target;
    always_comb begin
        if (sel_dram)       target = TARGET_DRAM;
        else if (sel_clint) target = TARGET_CLINT;
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
            TARGET_DRAM:  begin ack_o = dram_ack_i;  err_o = dram_err_i;  dat_o = dram_dat_i;  end
            default:      begin ack_o = ram_ack_i;   err_o = ram_err_i;   dat_o = ram_dat_i;   end
        endcase
    end
endmodule
