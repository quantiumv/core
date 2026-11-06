// SPDX-License-Identifier: MIT

/*
 * qv_pmp -- the PMP check for one access: which of read, write and
 * execute it may do. Purely combinational, one instance per access
 * stream (each fetch parcel, data, the walker's PTE reads).
 *
 * The privileged spec's rule (Sail's too), errata E5:
 *   - four regions (pmpcfg0 bytes: L[7], A[4:3], X[2], W[1], R[0]),
 *     OFF / TOR / NA4 / NAPOT, each a byte range [lo, hi): TOR region i
 *     from pmpaddr[i-1] (0 for region 0) to pmpaddr[i], empty unless
 *     pmpaddr[i-1] < pmpaddr[i]; NA4 the word at pmpaddr; NAPOT the range
 *     the trailing ones of pmpaddr encode (it can end at 2^56)
 *   - the lowest-numbered region holding ANY byte of the access decides;
 *     unless it holds ALL of them the access fails, whatever L, R, W and X
 *     say, in M mode too (before E5 such a region counted as no match and
 *     the search went on, so an 8-byte access across an NA4 or TOR edge
 *     could get through on a more permissive region)
 *   - no region holds a byte: M may, S and U may not
 *   - a deciding region that is unlocked does not limit M; otherwise (S/U,
 *     or locked) its R, W and X decide
 *   - privilege 2'b10 (MPP is loaded raw) is not M
 * The caller supplies the span [i_addr, i_end]: a fetch parcel's two
 * bytes, a data access's own bytes, a PTE's eight.
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

    // the access as [as, ae), 65 bits
    wire [64:0] as = {1'b0, i_addr};
    wire [64:0] ae = {1'b0, i_end} + 65'd1;

    wire [53:0] pa [4];
    assign pa[0] = i_pmpaddr0[53:0];
    assign pa[1] = i_pmpaddr1[53:0];
    assign pa[2] = i_pmpaddr2[53:0];
    assign pa[3] = i_pmpaddr3[53:0];

    // per region: its range, whether it holds any byte (touch) and all of them (holds)
    logic [3:0] touch, holds;
    logic [3:0] lck, xp, wp, rp;
    for (genvar i = 0; i < 4; i++) begin : g_region
        /* verilator lint_off UNUSEDSIGNAL */
        wire [7:0]  cfg  = i_pmpcfg0[8 * i +: 8];         // [6:5] are reserved
        /* verilator lint_on UNUSEDSIGNAL */
        wire [53:0] prev = (i == 0) ? 54'd0 : pa[(i == 0) ? 0 : i - 1];
        wire [53:0] wm   = pa[i] ^ (pa[i] + 54'd1);          // NAPOT: the trailing ones and the bit above
        wire [54:0] nb   = {1'b0, pa[i] & ~wm};              // NAPOT range in words
        wire [54:0] ne   = nb + {1'b0, wm} + 55'd1;
        logic [64:0] lo, hi;
        logic        ranged;
        always_comb begin
            lo = 65'd0;
            hi = 65'd0;
            ranged = 1'b0;
            case (cfg[4:3])
                2'b01: begin lo = {9'b0, prev, 2'b00};  hi = {9'b0, pa[i], 2'b00}; ranged = prev < pa[i]; end   // TOR
                2'b10: begin lo = {9'b0, pa[i], 2'b00}; hi = lo + 65'd4;           ranged = 1'b1;         end   // NA4
                2'b11: begin lo = {8'b0, nb, 2'b00};    hi = {8'b0, ne, 2'b00};    ranged = 1'b1;         end   // NAPOT
                default: ;                                                                                     // OFF
            endcase
        end
        assign touch[i] = ranged && !(ae <= lo || hi <= as);
        assign holds[i] = ranged && (lo <= as) && (ae <= hi);
        assign lck[i] = cfg[7];
        assign xp[i]  = cfg[2];
        assign wp[i]  = cfg[1];
        assign rp[i]  = cfg[0];
    end

    // the lowest-numbered region that touches the access decides
    wire touched = |touch;
    wire whole   = touch[0] ? holds[0] : touch[1] ? holds[1] : touch[2] ? holds[2] : holds[3];
    wire locked  = touch[0] ? lck[0]   : touch[1] ? lck[1]   : touch[2] ? lck[2]   : lck[3];
    wire rperm   = touch[0] ? rp[0]    : touch[1] ? rp[1]    : touch[2] ? rp[2]    : rp[3];
    wire wperm   = touch[0] ? wp[0]    : touch[1] ? wp[1]    : touch[2] ? wp[2]    : wp[3];
    wire xperm   = touch[0] ? xp[0]    : touch[1] ? xp[1]    : touch[2] ? xp[2]    : xp[3];

    wire is_m   = (i_priv == PRIV_M);
    wire m_free = is_m && (!touched || (whole && !locked));
    wire perm_on = touched && whole;
    assign o_read_ok  = m_free || (perm_on && rperm);
    assign o_write_ok = m_free || (perm_on && wperm);
    assign o_exec_ok  = m_free || (perm_on && xperm);
endmodule
