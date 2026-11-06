// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: plic
 *
 * A real, addressable Wishbone-slave PLIC (Platform-Level Interrupt
 * Controller), deliberately minimal for this milestone (PMP+PLIC plan
 * Milestone 4): exactly 1 real interrupt source (ID 1, reserved for
 * UART RX) and 2 real hart contexts (context 0 = M-mode -> o_meip,
 * context 1 = S-mode -> o_seip). MSI/SSI/STI/LCOFI sources, additional
 * interrupt sources, and additional contexts are all out of scope --
 * see the plan's own cross-cutting decision #6.
 *
 * Real spec register map (riscv/riscv-plic-spec, riscv-plic.adoc),
 * independently transcribed here, not read from any other file's
 * internals -- every register is 32 bits, LW/SW-atomic:
 *   +0x000000  priority array. Source 0 (reserved) at +0x0, source 1
 *              (the only real source) at +0x4 -- 4 bytes/source.
 *   +0x001000  pending bitmap. Source 1's pending bit is bit 1 of the
 *              32-bit word at this offset (bit 0, source 0, reserved).
 *   +0x002000  context 0's enable bitmap (bit 1 = source 1).
 *   +0x002080  context 1's enable bitmap (bit 1 = source 1) --
 *              +0x80/context, per-context stride, regardless of how
 *              few contexts are actually implemented.
 *   +0x200000  context 0's threshold (low 32 bits of this dword) and
 *              claim/complete (high 32 bits of the SAME dword, +0x4 --
 *              read claims, write completes).
 *   +0x201000  context 1's threshold/claim/complete, same shape,
 *              +0x1000/context (a spec-fixed offset, independent of how
 *              few contexts exist).
 * Only addr_i[21:0] is ever consulted -- upstream (wb_addr_decoder.sv,
 * Milestone 5, not yet wired) already decided everything above that.
 *
 * The 32-bit-register-in-a-64-bit-bus split (e.g. threshold vs.
 * claim/complete sharing one dword, or source0 vs. source1 sharing the
 * priority dword) needs NO deliberate packing logic here -- core.sv's
 * own mem_sel/wb_sel_o already derive the correct byte-lane mask for
 * any sub-dword LW/SW at any address, so a real 32-bit access to the
 * dword's own +0x4 half naturally arrives as sel_i=8'hF0 with the real
 * value in dat_i[63:32]/expected in dat_o[63:32] -- this falls
 * straight out of the existing byte-addressable bus convention
 * clint.sv's own per-byte-lane mtimecmp write already relies on.
 *
 * Registered, 1-wait-state ack, matching clint.sv's/uart_tx.sv's own
 * house style exactly. err_o is never asserted -- wb_addr_decoder.sv is
 * the only thing that ever routes a request here, and any address in
 * this window not matching a real register aliases harmlessly (reads
 * 0, ignores writes) rather than faulting, same convention clint.sv's
 * own out-of-register-map addresses already use.
 *
 * Gateway/pending semantics (real spec text, "Interrupt Gateways"):
 * i_uart_rx_irq is a LEVEL, not a pulse (same convention mtip_o's own
 * consumer already expects). A rising level while NOT already served
 * creates a new pending request; the request persists even if the
 * level later drops before being claimed; claiming clears pending and
 * sets served (no new pending request can form while served, even if
 * the level is still asserted or re-asserts); completing clears served
 * -- if the level is STILL asserted at that point, the very next cycle
 * immediately re-creates a pending request and re-asserts EIP.
 */
module plic (
    input logic clk,
    input logic rst,

    /*
     * addr_i: only bits [21:3] (the dword select) are ever consulted --
     * bits [2:0] (byte offset within the dword) are sel_i's job instead,
     * and bits [31:22] are upstream's own already-decided routing bits
     * (same pattern clint.sv's own addr_i wraps for the same reason).
     * dat_i: only the narrow real fields within each 32-bit half are
     * ever read (bit 1 for enable, bits [2:0] for threshold/priority,
     * the whole high half for a completion's own ID check) -- the
     * untouched middle bits of each half are always-reserved-zero
     * territory per spec, never read here, same "genuinely don't care"
     * situation, not a stale pragma.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] addr_i,
    input  logic [63:0] dat_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,
    input  logic         we_i,
    input  logic         cyc_i,
    input  logic         stb_i,
    output logic         ack_o,
    output logic         err_o,

    input  logic i_uart_rx_irq,
    output logic o_meip,
    output logic o_seip
);

    localparam [21:0] PRIORITY_DWORD0  = 22'h000000;
    localparam [21:0] PENDING_DWORD0   = 22'h001000;
    localparam [21:0] ENABLE_CTX0      = 22'h002000;
    localparam [21:0] ENABLE_CTX1      = 22'h002080;
    localparam [21:0] THRESHCLAIM_CTX0 = 22'h200000;
    localparam [21:0] THRESHCLAIM_CTX1 = 22'h201000;

    // Source 1's own ID -- a real constant, not "1" sprinkled ad hoc
    // through the file, since it's compared against BOTH the claim
    // response and an incoming completion write's own value.
    localparam [31:0] SOURCE1_ID = 32'd1;

    logic [21:0] dword_addr;
    assign dword_addr = {addr_i[21:3], 3'b0};

    wire sel_priority = (dword_addr == PRIORITY_DWORD0);
    wire sel_pending  = (dword_addr == PENDING_DWORD0);
    wire sel_enable0  = (dword_addr == ENABLE_CTX0);
    wire sel_enable1  = (dword_addr == ENABLE_CTX1);
    wire sel_thresh0  = (dword_addr == THRESHCLAIM_CTX0);
    wire sel_thresh1  = (dword_addr == THRESHCLAIM_CTX1);

    // Every real register this module implements is 32 bits; sel_i's
    // own two nibbles say which half of the addressed dword the master
    // actually means (low = the first-listed field above, high = the
    // second, where a dword holds two distinct fields at all).
    wire lo_half_sel = sel_i[3:0] != 4'b0;
    wire hi_half_sel = sel_i[7:4] != 4'b0;

    logic [2:0] priority1_q;
    logic       pending_q;
    logic       served_q;
    logic       enable_ctx0_q, enable_ctx1_q;
    logic [2:0] threshold_ctx0_q, threshold_ctx1_q;

    wire eip_ctx0 = pending_q && enable_ctx0_q && (priority1_q > threshold_ctx0_q);
    wire eip_ctx1 = pending_q && enable_ctx1_q && (priority1_q > threshold_ctx1_q);
    assign o_meip = eip_ctx0;
    assign o_seip = eip_ctx1;

    wire bus_fire = cyc_i && stb_i;  // registered ack below fires exactly one cycle after this

    wire write_priority = bus_fire && we_i && sel_priority && hi_half_sel;
    wire write_enable0  = bus_fire && we_i && sel_enable0  && lo_half_sel;
    wire write_enable1  = bus_fire && we_i && sel_enable1  && lo_half_sel;
    wire write_thresh0  = bus_fire && we_i && sel_thresh0  && lo_half_sel;
    wire write_thresh1  = bus_fire && we_i && sel_thresh1  && lo_half_sel;

    // A completion write is only honored if that context is currently
    // enabled for source 1 and the written value is genuinely source
    // 1's own ID -- per spec, a completion for a source/context that
    // isn't actually enabled, or the wrong ID, is silently ignored.
    wire complete_ctx0 = bus_fire && we_i && sel_thresh0 && hi_half_sel
                        && enable_ctx0_q && (dat_i[63:32] == SOURCE1_ID);
    wire complete_ctx1 = bus_fire && we_i && sel_thresh1 && hi_half_sel
                        && enable_ctx1_q && (dat_i[63:32] == SOURCE1_ID);

    // A claim read only actually claims if that context is genuinely
    // eligible right now -- an ineligible read just returns 0 (ID 0 =
    // "no interrupt"), consuming nothing.
    wire claim_ctx0 = bus_fire && !we_i && sel_thresh0 && hi_half_sel && eip_ctx0;
    wire claim_ctx1 = bus_fire && !we_i && sel_thresh1 && hi_half_sel && eip_ctx1;

    always_ff @(posedge clk) begin
        if (rst) begin
            priority1_q      <= 3'b0;
            enable_ctx0_q    <= 1'b0;
            enable_ctx1_q    <= 1'b0;
            threshold_ctx0_q <= 3'b0;
            threshold_ctx1_q <= 3'b0;
        end else begin
            if (write_priority) priority1_q      <= dat_i[34:32];
            if (write_enable0)  enable_ctx0_q    <= dat_i[1];
            if (write_enable1)  enable_ctx1_q    <= dat_i[1];
            if (write_thresh0)  threshold_ctx0_q <= dat_i[2:0];
            if (write_thresh1)  threshold_ctx1_q <= dat_i[2:0];
        end
    end

    /*
     * pending_q/served_q: the gateway's own request-latch, independent
     * of any bus access -- a rising i_uart_rx_irq while not already
     * served creates a new pending request; claiming (from EITHER
     * context -- with only 1 real source, "highest-priority pending"
     * degenerates to a single shared latch both contexts race to claim)
     * clears pending and sets served; completing (from the SAME context
     * that claimed, though this module doesn't track which one) clears
     * served, and if the level is still asserted, the very next cycle's
     * own "level asserted && !served" condition immediately re-latches
     * pending -- a real, spec-correct one-cycle-later re-arm, not a
     * same-cycle same-source retrigger.
     */
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= 1'b0;
            served_q  <= 1'b0;
        end else begin
            if (claim_ctx0 || claim_ctx1) begin
                pending_q <= 1'b0;
                served_q  <= 1'b1;
            end else if (i_uart_rx_irq && !served_q) begin
                pending_q <= 1'b1;
            end
            if (complete_ctx0 || complete_ctx1) begin
                served_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            ack_o <= 1'b0;
            err_o <= 1'b0;
            dat_o <= 64'b0;
        end else if (bus_fire) begin
            ack_o <= 1'b1;
            err_o <= 1'b0;
            if (sel_priority)     dat_o <= {29'b0, priority1_q, 32'b0};
            else if (sel_pending) dat_o <= {32'b0, 30'b0, pending_q, 1'b0};
            else if (sel_enable0) dat_o <= {32'b0, 30'b0, enable_ctx0_q, 1'b0};
            else if (sel_enable1) dat_o <= {32'b0, 30'b0, enable_ctx1_q, 1'b0};
            else if (sel_thresh0) dat_o <= {(claim_ctx0 ? SOURCE1_ID : 32'b0), 29'b0, threshold_ctx0_q};
            else if (sel_thresh1) dat_o <= {(claim_ctx1 ? SOURCE1_ID : 32'b0), 29'b0, threshold_ctx1_q};
            else                  dat_o <= 64'b0;
        end else begin
            ack_o <= 1'b0;
            err_o <= 1'b0;
        end
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
