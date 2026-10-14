// SPDX-License-Identifier: MIT

/*
 * qv_pmp -- the PMP check for one access: which of read, write and
 * execute it may do. Purely combinational, one instance per access
 * stream (fetch low span, fetch high span, data).
 *
 * A literal copy of core.sv's expressions, quirks included, so the two
 * cores agree access for access:
 *   - four regions (pmpcfg0 bytes: L[7], A[4:3], X[2], W[1], R[0]),
 *     OFF / TOR / NA4 / NAPOT; TOR region 0 starts at address 0
 *   - a region matches only if the WHOLE span [i_addr, i_end] is inside
 *     it; a partial overlap is no match at all, and the check carries on
 *     to the next region
 *   - the lowest-numbered matching region decides
 *   - M mode (the effective privilege passed in) is allowed when nothing
 *     matches or the matching region is unlocked; otherwise (S/U, or a
 *     locked match) the matching region's own permission decides, and no
 *     match at all means no access below M
 *   - privilege 2'b10 (MPP is loaded raw) is not M
 *   - NA4 compares only address bits [55:2]; NAPOT and TOR compare the
 *     full 64 bits, so an address above bit 55 never matches a NAPOT
 *     region
 * The caller supplies the span: the fetch streams use [pc, pc+7] and
 * [pc+8, pc+15] (whatever the instruction really needs), data uses the
 * access itself, [addr, addr + size - 1].
 */
module qv_pmp (
    // csr_file0's exports; only pmpcfg0[31:0] and pmpaddrN[53:0] mean anything
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] i_pmpcfg0,
    input  logic [63:0] i_pmpaddr0,
    input  logic [63:0] i_pmpaddr1,
    input  logic [63:0] i_pmpaddr2,
    input  logic [63:0] i_pmpaddr3,
    /* verilator lint_on UNUSEDSIGNAL */

    input  logic [63:0] i_addr,          // first byte of the access
    input  logic [63:0] i_end,           // last byte of the access
    input  logic [1:0]  i_priv,          // privilege the check runs at

    output logic        o_read_ok,
    output logic        o_write_ok,
    output logic        o_exec_ok
);
    localparam logic [1:0] PRIV_M = 2'b11;

    // region fields
    wire        l0 = i_pmpcfg0[7],  l1 = i_pmpcfg0[15], l2 = i_pmpcfg0[23], l3 = i_pmpcfg0[31];
    wire [1:0]  a0 = i_pmpcfg0[4:3], a1 = i_pmpcfg0[12:11], a2 = i_pmpcfg0[20:19], a3 = i_pmpcfg0[28:27];
    wire        x0 = i_pmpcfg0[2],  x1 = i_pmpcfg0[10], x2 = i_pmpcfg0[18], x3 = i_pmpcfg0[26];
    wire        w0 = i_pmpcfg0[1],  w1 = i_pmpcfg0[9],  w2 = i_pmpcfg0[17], w3 = i_pmpcfg0[25];
    wire        r0 = i_pmpcfg0[0],  r1 = i_pmpcfg0[8],  r2 = i_pmpcfg0[16], r3 = i_pmpcfg0[24];

    // byte-address bounds: pmpaddrN holds address[55:2]
    wire [63:0] base0 = {8'b0, i_pmpaddr0[53:0], 2'b0};
    wire [63:0] base1 = {8'b0, i_pmpaddr1[53:0], 2'b0};
    wire [63:0] base2 = {8'b0, i_pmpaddr2[53:0], 2'b0};
    wire [63:0] base3 = {8'b0, i_pmpaddr3[53:0], 2'b0};

    // NAPOT: the trailing ones of pmpaddr give the size
    wire [53:0] wm0 = i_pmpaddr0[53:0] ^ (i_pmpaddr0[53:0] + 54'd1);
    wire [53:0] wm1 = i_pmpaddr1[53:0] ^ (i_pmpaddr1[53:0] + 54'd1);
    wire [53:0] wm2 = i_pmpaddr2[53:0] ^ (i_pmpaddr2[53:0] + 54'd1);
    wire [53:0] wm3 = i_pmpaddr3[53:0] ^ (i_pmpaddr3[53:0] + 54'd1);
    wire [63:0] nm0 = {8'b0, wm0, 2'b11};
    wire [63:0] nm1 = {8'b0, wm1, 2'b11};
    wire [63:0] nm2 = {8'b0, wm2, 2'b11};
    wire [63:0] nm3 = {8'b0, wm3, 2'b11};
    wire [63:0] nb0 = base0 & ~nm0;
    wire [63:0] nb1 = base1 & ~nm1;
    wire [63:0] nb2 = base2 & ~nm2;
    wire [63:0] nb3 = base3 & ~nm3;

    wire m0 = (a0 == 2'b00) ? 1'b0
        : (a0 == 2'b10) ? (i_addr[55:2] == i_pmpaddr0[53:0] && i_end[55:2] == i_pmpaddr0[53:0])
        : (a0 == 2'b01) ? (i_end < base0)
        :                 ((i_addr & ~nm0) == nb0 && (i_end & ~nm0) == nb0);
    wire m1 = (a1 == 2'b00) ? 1'b0
        : (a1 == 2'b10) ? (i_addr[55:2] == i_pmpaddr1[53:0] && i_end[55:2] == i_pmpaddr1[53:0])
        : (a1 == 2'b01) ? (i_addr >= base0 && i_end < base1)
        :                 ((i_addr & ~nm1) == nb1 && (i_end & ~nm1) == nb1);
    wire m2 = (a2 == 2'b00) ? 1'b0
        : (a2 == 2'b10) ? (i_addr[55:2] == i_pmpaddr2[53:0] && i_end[55:2] == i_pmpaddr2[53:0])
        : (a2 == 2'b01) ? (i_addr >= base1 && i_end < base2)
        :                 ((i_addr & ~nm2) == nb2 && (i_end & ~nm2) == nb2);
    wire m3 = (a3 == 2'b00) ? 1'b0
        : (a3 == 2'b10) ? (i_addr[55:2] == i_pmpaddr3[53:0] && i_end[55:2] == i_pmpaddr3[53:0])
        : (a3 == 2'b01) ? (i_addr >= base2 && i_end < base3)
        :                 ((i_addr & ~nm3) == nb3 && (i_end & ~nm3) == nb3);

    // the lowest-numbered match decides
    wire matched = m0 || m1 || m2 || m3;
    wire rperm   = m0 ? r0 : m1 ? r1 : m2 ? r2 : r3;
    wire wperm   = m0 ? w0 : m1 ? w1 : m2 ? w2 : w3;
    wire xperm   = m0 ? x0 : m1 ? x1 : m2 ? x2 : x3;
    wire locked  = m0 ? l0 : m1 ? l1 : m2 ? l2 : l3;

    wire m_free = (i_priv == PRIV_M) && (!matched || !locked);
    assign o_read_ok  = m_free ? 1'b1 : (matched && rperm);
    assign o_write_ok = m_free ? 1'b1 : (matched && wperm);
    assign o_exec_ok  = m_free ? 1'b1 : (matched && xperm);
endmodule
