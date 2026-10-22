// SPDX-License-Identifier: MIT

/*
 * qv_tlb -- a small fully associative Sv39 TLB, superpage aware.
 *
 * core.sv's rules, kept so the two cores fill and evict alike where it
 * matters (the pipe has one of these for fetch and one for data, the FSM a
 * single unified one, so which entry is evicted differs on a program that
 * touches more pages than fit -- invisible to a program that follows the
 * SFENCE.VMA rule):
 *   - an entry caches the level it was found at, the raw PTE's PPN, and
 *     r/w/x/u/d. There is no A bit (a fill needs A = 1), no ASID, no
 *     global bit. Faults are never cached: the caller fills only for a leaf
 *     that passed every check for the access that triggered the walk
 *   - the tag is VA[38:12], compared only down to the entry's level: a
 *     gigapage compares vpn2, a megapage vpn2:vpn1, a 4 KB page all three
 *   - the lowest-numbered matching entry wins
 *   - a fill goes into the victim slot, and the victim pointer then moves
 *     to the next slot (round robin). Reset starts it at 0; a flush leaves
 *     it where it is
 *   - a flush (SFENCE.VMA) invalidates every entry; it beats a fill in the
 *     same cycle (the caller never presents both)
 * What a hit means -- the permission / U / A / D re-check against the live
 * context -- is qv_pte's job, fed from these outputs.
 */
module qv_tlb #(
    parameter int ENTRIES = 4
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        i_flush,

    // lookup, combinational
    input  logic [26:0] i_vpn,            // VA[38:12]
    output logic        o_hit,
    output logic [1:0]  o_level,
    output logic [43:0] o_ppn,            // the cached PTE's ppn2/ppn1/ppn0, as it was
    output logic        o_r,
    output logic        o_w,
    output logic        o_x,
    output logic        o_u,
    output logic        o_d,

    // fill
    input  logic        i_fill,
    input  logic [26:0] i_fill_vpn,
    input  logic [1:0]  i_fill_level,
    input  logic [43:0] i_fill_ppn,
    input  logic        i_fill_r,
    input  logic        i_fill_w,
    input  logic        i_fill_x,
    input  logic        i_fill_u,
    input  logic        i_fill_d
);
    localparam int VW = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;

    logic [ENTRIES-1:0] valid_q;
    logic [1:0]         level_q [0:ENTRIES-1];
    logic [26:0]        vpn_q   [0:ENTRIES-1];
    logic [43:0]        ppn_q   [0:ENTRIES-1];
    logic [ENTRIES-1:0] r_q, w_q, x_q, u_q, d_q;
    logic [VW-1:0]      victim_q;

    // ---------------- lookup ----------------
    // the tag is compared only down to the entry's level
    logic [ENTRIES-1:0] hit_v;
    for (genvar g = 0; g < ENTRIES; g++) begin : g_hit
        wire m_giga = (vpn_q[g][26:18] == i_vpn[26:18]);
        wire m_mega = (vpn_q[g][26:9]  == i_vpn[26:9]);
        wire m_page = (vpn_q[g]        == i_vpn);
        assign hit_v[g] = valid_q[g] && ((level_q[g] == 2'd2) ? m_giga : (level_q[g] == 2'd1) ? m_mega : m_page);
    end

    always_comb begin
        o_hit   = 1'b0;
        o_level = 2'd0;
        o_ppn   = '0;
        o_r = 1'b0; o_w = 1'b0; o_x = 1'b0; o_u = 1'b0; o_d = 1'b0;
        for (int i = ENTRIES - 1; i >= 0; i--) begin      // the lowest index is assigned last, so it wins
            if (hit_v[i]) begin
                o_hit   = 1'b1;
                o_level = level_q[i];
                o_ppn   = ppn_q[i];
                o_r = r_q[i]; o_w = w_q[i]; o_x = x_q[i]; o_u = u_q[i]; o_d = d_q[i];
            end
        end
    end

    // ---------------- fill, flush ----------------
    wire [VW-1:0] victim_next = (victim_q == VW'(ENTRIES - 1)) ? '0 : victim_q + 1'b1;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_q  <= '0;
            victim_q <= '0;
        end else if (i_flush) begin
            valid_q  <= '0;
        end else if (i_fill) begin
            valid_q[victim_q]  <= 1'b1;
            level_q[victim_q]  <= i_fill_level;
            vpn_q[victim_q]    <= i_fill_vpn;
            ppn_q[victim_q]    <= i_fill_ppn;
            r_q[victim_q]      <= i_fill_r;
            w_q[victim_q]      <= i_fill_w;
            x_q[victim_q]      <= i_fill_x;
            u_q[victim_q]      <= i_fill_u;
            d_q[victim_q]      <= i_fill_d;
            victim_q           <= victim_next;
        end
    end
endmodule
