// SPDX-License-Identifier: MIT

/*
 * qv_pte -- one Sv39 PTE, judged: is it a leaf, does the access fault on it,
 * and where does a leaf point. Purely combinational.
 *
 * Used twice. The walker judges each PTE it reads (the bus data at level 2,
 * 1 and 0). A TLB lookup feeds it a PTE synthesized from the cached entry
 * (V and A set, the cached r/w/x/u/d and ppn), so a hit re-runs the same
 * checks against the live privilege, SUM, MXR, access kind and virtual
 * address and no formula exists twice -- the way ref_core.sv shares one block.
 *
 * A literal copy of ref_core.sv's expressions (2557-2641), quirks included:
 *   - a leaf is R or X (a PTE with W and not R is malformed, so it faults
 *     before it can matter)
 *   - malformed: V clear, W without R, a reserved bit (60:54), PBMT (62:61)
 *     or N (63) set -- for a pointer PTE too
 *   - a superpage leaf must have its low PPN segments zero (level 2: PPN[1:0],
 *     level 1: PPN[0])
 *   - a pointer at level 0 faults: nothing is left to walk into
 *   - a virtual address whose bits 63:39 are not all equal to bit 38 faults
 *     whatever PTE it meets (the walk still reads the level-2 PTE first)
 *   - U: a U page is for U privilege, and for S only to data accesses with
 *     SUM; a non-U page is for S (and M) and not for U. Fetch is never
 *     SUM-aware. Privilege 2'b10 (MPP is loaded raw) is neither U nor S, so
 *     the U rule never fires for it
 *   - permission: a fetch needs X; a data access needs W if it writes
 *     (store, SC, AMO), else R or (MXR and X)
 *   - Svade: A clear always faults, D clear faults a data write. Nothing
 *     is ever written back
 * The address of a leaf is PA = {8'b0, ppn2, ppn1, ppn0, va[11:0]}; for a
 * superpage the low PPN segments come from the VA, not from the PTE.
 */
module qv_pte (
    // bits 9:8 (RSW) and 5 (G) mean nothing to the walker
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] i_pte,         // as read, or synthesized from a TLB entry
    input  logic [63:0] i_va,          // the virtual address being translated, live (bits 11:0 are not looked at)
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [1:0]  i_level,       // the level the PTE was read at: 2, 1 or 0
    input  logic        i_is_mem,      // a data access (else a fetch)
    input  logic        i_wr,          // the data access writes: a store, SC or AMO (not LR)
    input  logic [1:0]  i_priv,        // privilege of the access: the current one for a fetch, the MPRV-effective one for data
    input  logic        i_sum,
    input  logic        i_mxr,

    output logic        o_leaf,        // R or X set
    output logic        o_fault,       // a page fault; for a pointer: malformed, or no level left
    output logic [43:0] o_ppn,         // PA[55:12] of the translated address: meaningful for a leaf without a fault
    output logic [43:0] o_next_ppn     // for a pointer: the page number of the next table
);
    wire        v    = i_pte[0];
    wire        r    = i_pte[1];
    wire        w    = i_pte[2];
    wire        x    = i_pte[3];
    wire        u    = i_pte[4];
    wire        a    = i_pte[6];
    wire        d    = i_pte[7];
    wire [8:0]  ppn0 = i_pte[18:10];
    wire [8:0]  ppn1 = i_pte[27:19];
    wire [25:0] ppn2 = i_pte[53:28];
    wire [6:0]  rsvd = i_pte[60:54];
    wire [1:0]  pbmt = i_pte[62:61];
    wire        n    = i_pte[63];

    wire leaf           = r || x;
    wire noncanonical   = i_va[63:39] != {25{i_va[38]}};
    wire malformed      = !v || (!r && w) || (|rsvd) || (|pbmt) || n;
    wire misaligned     = leaf && (i_level != 2'd0) && ((i_level == 2'd2) ? (|{ppn1, ppn0}) : (|ppn0));
    wire no_more_levels = !leaf && (i_level == 2'd0);

    wire priv_u    = (i_priv == 2'b00);
    wire priv_s    = (i_priv == 2'b01);
    wire u_viol    = leaf && (u ? (i_is_mem ? !(priv_u || (priv_s && i_sum)) : priv_s) : priv_u);
    wire read_ok   = r || (i_mxr && x);
    wire perm_viol = leaf && (i_is_mem ? (i_wr ? !w : !read_ok) : !x);
    wire ad_fault  = leaf && (!a || (i_is_mem && i_wr && !d));

    assign o_leaf  = leaf;
    assign o_fault = noncanonical || malformed || misaligned || no_more_levels || u_viol || perm_viol || ad_fault;

    wire [8:0] vpn1 = i_va[29:21];
    wire [8:0] vpn0 = i_va[20:12];
    assign o_ppn      = {ppn2, (i_level <= 2'd1) ? ppn1 : vpn1, (i_level == 2'd0) ? ppn0 : vpn0};
    assign o_next_ppn = i_pte[53:10];
endmodule
