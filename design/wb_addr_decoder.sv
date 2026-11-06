// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: wb_addr_decoder
 *
 * Routes the CPU's single Wishbone master port to one of five slaves --
 * design/wb4_sram.sv (RAM), design/uart_tx.sv (UART), design/clint.sv
 * (CLINT), verification/taxi/rtl/dram_model.sv (DRAM), or
 * design/plic.sv (PLIC) -- based on address. One master, five fixed
 * slaves: hand-written rather than a general N-slave interconnect,
 * since that generality isn't needed here.
 *
 * Address map. A new top-level bit, addr_i[26] (sel_periph), was added
 * by the Linux-boot-readiness RAM-growth change to make room for RAM to
 * grow from 32KB to 64MB: sel_periph=0 routes to RAM unconditionally
 * (RAM now claims the ENTIRE 64MB region below addr_i[26], not just a
 * 32KB slice of it), sel_periph=1 routes to the same UART/CLINT/DRAM/PLIC
 * sub-decode this module already had, just shifted up by 0x0400_0000 (one
 * count of addr_i[26]) so it sits directly above the new, larger RAM
 * window instead of overlapping it. Every peripheral's own INTERNAL
 * sub-decode (the addr_i[22]/[16]/[15] tests below) is completely
 * unchanged -- only the outer gate moved:
 *   sel_periph=0 -> RAM   0x0000_0000-0x03FF_FFFF (wb4_sram.sv's
 *               num_words=8388608 x 8 bytes/word = 64MB, an explicit
 *               override on soc.sv's own real sram0 instance -- see
 *               soc.sv's header; wb4_sram.sv's own module default stays
 *               4096/32KB, unchanged, for every other instantiation)
 *   sel_periph=1, then:
 *     0xxx -> DRAM  0x0400_0000-0x0400_7FFF (32KB -- CLINT/UART
 *               standards-compliance plan Milestone 2: relocated here,
 *               into the hole CLINT's own widening below freed up, from
 *               its prior 0x0401_8000 home)
 *     0xxx -> UART  0x0400_8000-0x0400_FFFF (unchanged base -- a real
 *               16550's register set is tiny (8 bytes), fits easily in
 *               this existing 32KB window)
 *     1xxx -> CLINT 0x0401_0000-0x0401_FFFF (64KB -- widened from a prior
 *               32KB window by dropping the addr_i[15] qualifier from
 *               this select entirely, since a real per-hart CLINT needs
 *               up to +0xBFF8 for mtime; see design/clint.sv's own
 *               header for the real register offsets this now fits)
 *     1xxx -> PLIC  0x0440_0000-0x047F_FFFF (4MB, addr_i[22]=1 regardless
 *               of every other address bit -- room for 2 more real
 *               contexts later at no further decoder cost)
 *
 * The RAM/peripheral boundary (bit 26) is DERIVED from wb4_sram's
 * num_words override on soc.sv's real sram0 instance (8388608, 64MB), not
 * independent of it -- since RAM's size is a power of two starting at
 * address 0, "address >= 0x0400_0000" and "bit 26 set" are the same
 * condition, a single bit test rather than a shortcut that skips a real
 * range compare. NB: if that override ever changes, this decode bit needs
 * revisiting too. The UART/CLINT/DRAM/PLIC sub-boundaries (bits 22/16/15),
 * by contrast, are fresh, independently-chosen windows -- nothing derives
 * them from any slave's own size parameter; they were simply picked to
 * sit right above wherever the peripheral region starts, with room to
 * spare, and slide as a fixed block whenever the outer RAM window resizes.
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
 * Known, accepted gap: CLINT's own real register footprint is only 3
 * dwords (msip/mtimecmp/mtime at CLINT_BASE+0x0/+0x4000/+0xBFF8, see
 * clint.sv) but its decoded region is a full 64KB (a real per-hart
 * CLINT's own real spec footprint, widened from a prior 32KB window by
 * the CLINT/UART standards-compliance plan's own Milestone 1/2 -- see
 * clint.sv's own header for why 64KB, not something tighter, is the
 * real number). Unlike before this milestone, every address in that
 * window that isn't exactly one of the three real offsets is NOT an
 * address-aliasing risk any more -- clint.sv itself now does a real
 * equality decode per register and returns 0/ignores writes for
 * anything else (see that module's own header), so THIS module's own
 * bit-level gating (addr_i[16] alone, regardless of addr_i[15:0]) is
 * simply coarser than clint.sv's own internal decode, not a correctness
 * gap either module needs to close further without a concrete need
 * (e.g. real device-tree/OpenSBI address decoding) driving one.
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
 * the raw system address (nonzero bits 22/26 -- sel_periph and the
 * PLIC-window gate -- for every legitimately-routed DRAM address; bits
 * 15/16 are now naturally 0 there instead, following DRAM's own
 * relocation to sit directly above RAM's window, see this file's own
 * address-map comment above) would fail that check on every single access,
 * permanently and silently breaking DRAM with err_o instead of ack_o --
 * so dram_addr_o is rebased to a window-local address instead
 * (`{17'b0, addr_i[14:0]}`), the one broadcast assign that isn't a bare
 * passthrough. plic_addr_o, by contrast, IS a bare passthrough --
 * plic.sv does its own real bounds decoding purely off addr_i[21:0]
 * (its own header: "upstream already decided the rest"), so the raw
 * system address (with bit 22 always set for anything legitimately
 * routed here) works unmodified, the same way ram/uart/clint_addr_o
 * already do for their own reasons.
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
    input  logic        dram_err_i,

    // PLIC-facing port.
    output logic [31:0] plic_addr_o,
    output logic [63:0] plic_dat_o,
    input  logic [63:0] plic_dat_i,
    output logic [7:0]  plic_sel_o,
    output logic        plic_we_o,
    output logic        plic_cyc_o,
    output logic        plic_stb_o,
    input  logic        plic_ack_i,
    input  logic        plic_err_i
);
    wire sel_periph =  addr_i[26];
    wire sel_ram    = !sel_periph;
    wire sel_plic   =  sel_periph &&  addr_i[22];
    wire sel_uart   =  sel_periph && !addr_i[22] && !addr_i[16] &&  addr_i[15];
    wire sel_clint  =  sel_periph && !addr_i[22] &&  addr_i[16];
    wire sel_dram   =  sel_periph && !addr_i[22] && !addr_i[16] && !addr_i[15];

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
    assign plic_cyc_o  = cyc_i && sel_plic;
    assign plic_stb_o  = stb_i && sel_plic;

    assign ram_addr_o   = addr_i;
    assign uart_addr_o  = addr_i;
    assign clint_addr_o = addr_i;
    assign dram_addr_o  = {17'b0, addr_i[14:0]}; // rebased -- see "DRAM address
                                                  // translation" in the header.
    assign plic_addr_o  = addr_i;                // bare passthrough -- see the header.
    assign ram_dat_o    = dat_i;
    assign uart_dat_o   = dat_i;
    assign clint_dat_o  = dat_i;
    assign dram_dat_o   = dat_i;
    assign plic_dat_o   = dat_i;
    assign ram_sel_o    = sel_i;
    assign uart_sel_o   = sel_i;
    assign clint_sel_o  = sel_i;
    assign dram_sel_o   = sel_i;
    assign plic_sel_o   = sel_i;
    assign ram_we_o     = we_i;
    assign uart_we_o    = we_i;
    assign clint_we_o   = we_i;
    assign dram_we_o    = we_i;
    assign plic_we_o    = we_i;

    /*
     * Latched at the cycle a request is actually issued (cyc_i && stb_i),
     * held until the next request overwrites it -- see the module header
     * for why this can't just re-check addr_i when the response arrives.
     * Widened to 3 bits for PLIC -- 5 real targets now, 3 spare encodings
     * deliberately left unfilled (not artificially assigned to anything).
     */
    typedef enum logic [2:0] { TARGET_RAM, TARGET_UART, TARGET_CLINT, TARGET_DRAM, TARGET_PLIC } target_t;

    // RAM stays the terminal `else` here (equivalent to sel_ram by
    // construction, since the 5-way decode above is exhaustive) rather
    // than an explicit `if (sel_ram)` arm -- matches this file's existing
    // defensive-catch-all style (mirrored below in the read-mux `default:`).
    target_t target;
    always_comb begin
        if (sel_plic)       target = TARGET_PLIC;
        else if (sel_dram)  target = TARGET_DRAM;
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
            TARGET_PLIC:  begin ack_o = plic_ack_i;  err_o = plic_err_i;  dat_o = plic_dat_i;  end
            default:      begin ack_o = ram_ack_i;   err_o = ram_err_i;   dat_o = ram_dat_i;   end
        endcase
    end
endmodule
