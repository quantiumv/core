// SPDX-License-Identifier: MIT

/*
 * qv_xlate -- address translation for one client of core_pipe (the data side
 * or the instruction side): a TLB, the check of a hit, and the handshake
 * with the shared walker qv_ptw.
 *
 * The request comes from a register in the user (the LSU's address, the
 * fetch unit's request pc) together with the live context it is translated
 * in, and is held until o_done or i_cancel. The answer is combinational from
 * that registered request and the TLB, so the user registers it itself and
 * no TLB-to-PMP-to-bus path exists:
 *   - translation off (i_active low: Bare, M mode, a Program Buffer run):
 *     done in the same cycle, no fault (the user normally bypasses this)
 *   - a TLB hit: done in the cycle the request is presented. The entry is
 *     judged against the live privilege, SUM, MXR, access kind and virtual
 *     address (qv_pte on a PTE synthesized from the entry: V and A set, the
 *     cached r/w/x/u/d and page number), exactly the checks of a walk, so a
 *     hit can fault: o_pf, with nothing walked and nothing changed
 *   - a miss: the walker is asked (o_w_req, held until its done pulse). A
 *     leaf without a fault is cached at the edge that ends the done cycle
 *     and the held request then hits; a fault (page fault, or an access
 *     fault: PTE read denied by the PMP or a bus error) is remembered until
 *     the request goes away, and is never cached
 * i_cancel kills the request and the walk and clears a remembered fault;
 * i_flush_tlb (SFENCE.VMA) empties the TLB and does the same. Both beat a
 * fill that would land in the same cycle, so a walk that was cancelled, or
 * overtaken by a flush, leaves nothing behind.
 */
module qv_xlate #(
    parameter int TLB_ENTRIES = 4
) (
    input  logic        clk,
    input  logic        rst,

    // the request
    input  logic        i_req,
    input  logic [63:0] i_va,
    input  logic        i_is_mem,
    input  logic        i_wr,
    input  logic        i_active,
    input  logic [1:0]  i_priv,
    input  logic        i_sum,
    input  logic        i_mxr,
    input  logic        i_cancel,
    input  logic        i_flush_tlb,

    // the answer
    output logic        o_done,
    output logic        o_pf,                // page fault (12, 13 or 15 is the user's to choose)
    output logic        o_af,                // access fault (1, 5 or 7)
    output logic [43:0] o_ppn,               // PA[55:12] when done without a fault

    // the walker (its result bus is shared by both clients; i_w_done is this client's pulse)
    output logic        o_w_req,
    output logic        o_w_cancel,
    input  logic        i_w_done,
    input  logic        i_w_ok,
    input  logic        i_w_pf,
    input  logic        i_w_af,
    input  logic [26:0] i_w_vpn,
    input  logic [1:0]  i_w_level,
    input  logic [43:0] i_w_ppn,
    input  logic        i_w_r,
    input  logic        i_w_w,
    input  logic        i_w_x,
    input  logic        i_w_u,
    input  logic        i_w_d
);
    // ---------------- the TLB and the check of a hit ----------------
    logic        t_hit;
    logic [1:0]  t_level;
    logic [43:0] t_ppn;
    logic        t_r, t_w, t_x, t_u, t_d;

    wire fill = i_w_done && i_w_ok && i_req && !i_cancel && !i_flush_tlb;

    qv_tlb #(.ENTRIES(TLB_ENTRIES)) tlb0 (
        .clk(clk), .rst(rst), .i_flush(i_flush_tlb),
        .i_vpn(i_va[38:12]), .o_hit(t_hit), .o_level(t_level), .o_ppn(t_ppn),
        .o_r(t_r), .o_w(t_w), .o_x(t_x), .o_u(t_u), .o_d(t_d),
        .i_fill(fill), .i_fill_vpn(i_w_vpn), .i_fill_level(i_w_level), .i_fill_ppn(i_w_ppn),
        .i_fill_r(i_w_r), .i_fill_w(i_w_w), .i_fill_x(i_w_x), .i_fill_u(i_w_u), .i_fill_d(i_w_d)
    );

    // the entry as a PTE: V and A set (a fill needs A), no G, no reserved bits
    wire [63:0] syn = {10'b0, t_ppn, 2'b00, t_d, 1'b1, 1'b0, t_u, t_x, t_w, t_r, 1'b1};

    wire        h_fault;
    wire [43:0] h_ppn;
    /* verilator lint_off PINCONNECTEMPTY */
    qv_pte hit_pte (
        .i_pte(syn), .i_va(i_va), .i_level(t_level), .i_is_mem(i_is_mem), .i_wr(i_wr), .i_priv(i_priv),
        .i_sum(i_sum), .i_mxr(i_mxr),
        .o_leaf(), .o_fault(h_fault), .o_ppn(h_ppn), .o_next_ppn()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ---------------- a fault the walker found, until the request goes ----------------
    logic flt_q, fpf_q, faf_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            flt_q <= 1'b0;
        end else if (!i_req || i_cancel || i_flush_tlb) begin
            flt_q <= 1'b0;
        end else if (i_w_done && !i_w_ok) begin
            flt_q <= 1'b1;
            fpf_q <= i_w_pf;
            faf_q <= i_w_af;
        end
    end

    // ---------------- the answer ----------------
    wire [43:0] va_ppn = i_va[55:12];                      // the identity answer, for translation off

    always_comb begin
        o_done = 1'b0;
        o_pf   = 1'b0;
        o_af   = 1'b0;
        o_ppn  = va_ppn;
        if (i_req) begin
            if (!i_active) begin
                o_done = 1'b1;
            end else if (flt_q) begin
                o_done = 1'b1;
                o_pf   = fpf_q;
                o_af   = faf_q;
            end else if (t_hit) begin
                o_done = 1'b1;
                o_pf   = h_fault;
                o_ppn  = h_ppn;
            end
        end
    end

    // ask the walker only while there is nothing to answer yet; its done pulse ends the ask
    assign o_w_req    = i_req && i_active && !flt_q && !t_hit && !i_w_done;
    assign o_w_cancel = i_cancel || i_flush_tlb;
endmodule
