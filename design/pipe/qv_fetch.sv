// SPDX-License-Identifier: MIT

/*
 * qv_fetch -- PC generation and the Wishbone fetch master for core_pipe.
 *
 * One request outstanding at a time. Bus handshake matches core.sv's own
 * fetch port exactly: cyc/stb/addr are driven combinationally while a
 * request is outstanding and drop in the same cycle ack or err arrives,
 * so wb4_sram.sv (which re-acks every cycle cyc&&stb stays high) never
 * sees the request held into a second cycle and never produces a stale
 * "ghost" ack that a following request could mistake for its own.
 *
 * A request is never abandoned: a redirect marks the outstanding request
 * stale, it keeps cyc/stb/addr asserted until its own response arrives,
 * and that response is dropped. Dropping cyc early instead would let
 * wb_arbiter2 release the grant and route the late ack to the other
 * master. With one request outstanding a stale bit on it is exact; a
 * flipping epoch is not, since two redirects (align, then a trap at
 * commit) can land while one slow request is outstanding and flip it
 * back.
 *
 * A new request is issued only when the fetch buffer is guaranteed room
 * for its response (occupancy after this cycle's push/pop < FB_DEPTH) --
 * a Wishbone classic ack is one-shot and can't be refused. FB_DEPTH=2
 * lets fetch sustain one dword every two cycles against wb4_sram's
 * one-wait-state ack while decode keeps up.
 *
 * Bus address is always dword-aligned. The buffered pc is the actual
 * start pc, which can sit at pc[2]=1 for the first dword after a redirect
 * to a non-dword-aligned target; qv_align.sv skips the low half then.
 *
 * Sv39: with i_xl_on (translation on for fetch, sampled when a request is
 * issued) the request first goes through a translation phase -- it asks the
 * translator (qv_xlate, outside) for the physical page of its virtual
 * address -- and only then the bus. The phase lives in the request register
 * itself, so the single slot, the room rule and the stale bit stay as they
 * were:
 *   - translating (req_xl_q): nothing on the bus. A redirect ends it at
 *     once (drop: the slot is freed and the translation cancelled), so
 *     such a request is never stale. Under i_hold it may finish but never
 *     starts a bus beat, which keeps o_idle (and so FENCE.I) exact.
 *   - failed (req_flt_q): the translation said page fault or access fault.
 *     The request answers at once without a bus beat, with a fault entry
 *     for the fetch buffer (cause 12 or 1), through the same room the
 *     response would have used.
 *   - on the bus: as before, at {physical page, pc[11:3]}.
 * Each buffer entry carries the physical page it was fetched from, for the
 * PMP check decode makes per instruction.
 *
 * i_redirect_ctx marks a redirect that changes what the translation depends
 * on (privilege, satp, the TLB contents): the redirect target is recorded
 * but not issued that cycle, so a request is never translated against the
 * old context.
 */
module qv_fetch #(
    parameter logic [63:0] RESET_PC = 64'h0,
    parameter int          FB_DEPTH = 2
) (
    input  logic        clk,
    input  logic        rst,

    output logic [31:0] wb_fetch_addr_o,
    output logic        wb_fetch_cyc_o,
    output logic        wb_fetch_stb_o,
    input  logic [63:0] wb_fetch_dat_i,
    input  logic        wb_fetch_ack_i,
    input  logic        wb_fetch_err_i,

    input  logic        i_redirect_valid,
    input  logic [63:0] i_redirect_pc,
    input  logic        i_redirect_ctx = 1'b0,

    // FENCE.I: no new request while held, so once o_idle (nothing
    // outstanding) the icache can be flushed with no fill in flight
    input  logic        i_hold,
    output logic        o_idle,

    // translation (qv_xlate): the request is held until i_xl_done or o_xl_cancel
    input  logic        i_xl_on    = 1'b0,
    output logic        o_xl_req,
    output logic [63:0] o_xl_va,
    output logic        o_xl_cancel,
    input  logic        i_xl_done  = 1'b0,
    input  logic        i_xl_pf    = 1'b0,
    input  logic        i_xl_af    = 1'b0,
    input  logic [43:0] i_xl_ppn   = 44'b0,

    output logic        o_buf_valid,
    output logic [63:0] o_buf_pc,
    output logic [63:0] o_buf_data,
    output logic        o_buf_err,                 // a fault entry: o_buf_cause is its cause (1 or 12)
    output logic [3:0]  o_buf_cause,
    output logic        o_buf_xl,                  // the dword was fetched through translation: o_buf_pg is its physical page
    output logic [43:0] o_buf_pg,
    input  logic        i_buf_pop
);
    localparam int PTR_W = (FB_DEPTH > 1) ? $clog2(FB_DEPTH) : 1;
    localparam int CNT_W = $clog2(FB_DEPTH + 1);

    // ---------------- outstanding request ----------------
    logic        req_valid_q;
    logic [63:0] req_pc_q;
    logic        req_stale_q;    // redirected away from since it was issued (a request on the bus)
    logic        req_xl_q;       // translating: not on the bus yet
    logic        req_flt_q;      // the translation failed: an answer without a bus beat is due
    logic        req_pf_q;       // ... a page fault (cause 12), not an access fault (cause 1)
    logic        req_isxl_q;     // issued with translation on: req_pa_q is its physical page
    logic [43:0] req_pa_q;

    logic [63:0] fpc_q;          // next sequential fetch pc

    wire bus      = req_valid_q && !req_xl_q && !req_flt_q;
    wire bus_resp = bus && (wb_fetch_ack_i || wb_fetch_err_i);
    wire flt_resp = req_valid_q && req_flt_q;
    wire resp     = bus_resp || flt_resp;
    wire resp_ok  = resp && !req_stale_q && !i_redirect_valid;
    // a redirect ends a request that holds nothing on the bus at once
    wire drop     = i_redirect_valid && req_valid_q && (req_xl_q || req_flt_q);

    assign wb_fetch_cyc_o  = bus && !(wb_fetch_ack_i || wb_fetch_err_i);
    assign wb_fetch_stb_o  = wb_fetch_cyc_o;
    // the bus carries PA[31:0]: the physical page's low 20 bits, then the offset within the page
    assign wb_fetch_addr_o = req_isxl_q ? {req_pa_q[19:0], req_pc_q[11:3], 3'b000} : {req_pc_q[31:3], 3'b000};

    assign o_xl_req    = req_valid_q && req_xl_q;
    assign o_xl_va     = req_pc_q;
    assign o_xl_cancel = drop;

    // ---------------- fetch buffer (FB_DEPTH-entry FIFO) ----------------
    logic [63:0] fb_pc    [0:FB_DEPTH-1];
    logic [63:0] fb_data  [0:FB_DEPTH-1];
    logic        fb_err   [0:FB_DEPTH-1];
    logic [3:0]  fb_cause [0:FB_DEPTH-1];
    logic        fb_xl    [0:FB_DEPTH-1];
    logic [43:0] fb_pg    [0:FB_DEPTH-1];
    logic [PTR_W-1:0] fb_rd_q, fb_wr_q;
    logic [CNT_W-1:0] fb_count_q;

    wire fb_push = resp_ok;
    wire fb_pop  = i_buf_pop && (fb_count_q != '0) && !i_redirect_valid;

    logic [CNT_W-1:0] fb_count_next;
    always_comb begin
        if (i_redirect_valid) fb_count_next = '0;
        else                  fb_count_next = fb_count_q + CNT_W'(fb_push) - CNT_W'(fb_pop);
    end

    // Room for exactly one more response after this cycle settles, and no
    // request left outstanding past this edge. A redirect while held (or one
    // that changes the translation context) is recorded below and fetched
    // once the hold drops, or in the next cycle.
    wire can_issue = (!req_valid_q || resp || drop) && (fb_count_next < CNT_W'(FB_DEPTH)) && !i_hold
                     && !(i_redirect_valid && i_redirect_ctx);

    assign o_idle = !bus;

    wire [63:0] issue_pc    = i_redirect_valid ? i_redirect_pc : fpc_q;

    function automatic logic [PTR_W-1:0] ptr_inc(input logic [PTR_W-1:0] p);
        ptr_inc = (p == PTR_W'(FB_DEPTH - 1)) ? '0 : p + 1'b1;
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            req_valid_q <= 1'b0;
            req_pc_q    <= '0;
            req_stale_q <= 1'b0;
            req_xl_q    <= 1'b0;
            req_flt_q   <= 1'b0;
            req_pf_q    <= 1'b0;
            req_isxl_q  <= 1'b0;
            req_pa_q    <= '0;
            fpc_q       <= RESET_PC;
            fb_rd_q     <= '0;
            fb_wr_q     <= '0;
            fb_count_q  <= '0;
        end else begin
            if (can_issue) begin
                req_valid_q <= 1'b1;
                req_pc_q    <= issue_pc;
                req_stale_q <= 1'b0;
                req_xl_q    <= i_xl_on;
                req_flt_q   <= 1'b0;
                req_isxl_q  <= i_xl_on;
                fpc_q       <= {issue_pc[63:3], 3'b000} + 64'd8;
            end else begin
                if (resp || drop) req_valid_q <= 1'b0;
                if (i_redirect_valid) begin
                    req_stale_q <= 1'b1;
                    fpc_q       <= i_redirect_pc;
                end
                // the translation answered (a redirect in the same cycle wins: the request is dropped)
                if (req_valid_q && req_xl_q && i_xl_done && !i_redirect_valid) begin
                    if (i_xl_pf || i_xl_af) begin          // a fault needs no bus: it is allowed under hold
                        req_xl_q  <= 1'b0;
                        req_flt_q <= 1'b1;
                        req_pf_q  <= i_xl_pf;
                    end else if (!i_hold) begin             // a held fetch starts no bus beat
                        req_xl_q  <= 1'b0;
                        req_pa_q  <= i_xl_ppn;
                    end
                end
            end

            if (i_redirect_valid) begin
                fb_rd_q <= '0;
                fb_wr_q <= '0;
            end else begin
                if (fb_push) begin
                    fb_pc[fb_wr_q]    <= req_pc_q;
                    fb_data[fb_wr_q]  <= flt_resp ? 64'b0 : wb_fetch_dat_i;
                    fb_err[fb_wr_q]   <= flt_resp || wb_fetch_err_i;
                    fb_cause[fb_wr_q] <= (flt_resp && req_pf_q) ? 4'd12 : 4'd1;
                    fb_xl[fb_wr_q]    <= req_isxl_q;
                    fb_pg[fb_wr_q]    <= req_isxl_q ? req_pa_q : 44'b0;
                    fb_wr_q           <= ptr_inc(fb_wr_q);
                end
                if (fb_pop) fb_rd_q <= ptr_inc(fb_rd_q);
            end
            fb_count_q <= fb_count_next;
        end
    end

    assign o_buf_valid = (fb_count_q != '0);
    assign o_buf_pc    = fb_pc[fb_rd_q];
    assign o_buf_data  = fb_data[fb_rd_q];
    assign o_buf_err   = fb_err[fb_rd_q];
    assign o_buf_cause = fb_cause[fb_rd_q];
    assign o_buf_xl    = fb_xl[fb_rd_q];
    assign o_buf_pg    = fb_pg[fb_rd_q];
endmodule
