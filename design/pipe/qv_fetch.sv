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

    // FENCE.I: no new request while held, so once o_idle (nothing
    // outstanding) the icache can be flushed with no fill in flight
    input  logic        i_hold,
    output logic        o_idle,

    output logic        o_buf_valid,
    output logic [63:0] o_buf_pc,
    output logic [63:0] o_buf_data,
    output logic        o_buf_err,
    input  logic        i_buf_pop
);
    localparam int PTR_W = (FB_DEPTH > 1) ? $clog2(FB_DEPTH) : 1;
    localparam int CNT_W = $clog2(FB_DEPTH + 1);

    // ---------------- outstanding request ----------------
    logic        req_valid_q;
    logic [63:0] req_pc_q;
    logic        req_stale_q;    // redirected away from since it was issued

    logic [63:0] fpc_q;          // next sequential fetch pc

    wire resp     = req_valid_q && (wb_fetch_ack_i || wb_fetch_err_i);
    wire resp_ok  = resp && !req_stale_q && !i_redirect_valid;

    assign wb_fetch_cyc_o  = req_valid_q && !(wb_fetch_ack_i || wb_fetch_err_i);
    assign wb_fetch_stb_o  = wb_fetch_cyc_o;
    assign wb_fetch_addr_o = {req_pc_q[31:3], 3'b000};

    // ---------------- fetch buffer (FB_DEPTH-entry FIFO) ----------------
    logic [63:0] fb_pc   [0:FB_DEPTH-1];
    logic [63:0] fb_data [0:FB_DEPTH-1];
    logic        fb_err  [0:FB_DEPTH-1];
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
    // request left outstanding past this edge. A redirect while held is
    // recorded below and fetched once the hold drops.
    wire can_issue = (!req_valid_q || resp) && (fb_count_next < CNT_W'(FB_DEPTH)) && !i_hold;

    assign o_idle = !req_valid_q;

    wire [63:0] issue_pc    = i_redirect_valid ? i_redirect_pc : fpc_q;

    function automatic logic [PTR_W-1:0] ptr_inc(input logic [PTR_W-1:0] p);
        ptr_inc = (p == PTR_W'(FB_DEPTH - 1)) ? '0 : p + 1'b1;
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            req_valid_q <= 1'b0;
            req_pc_q    <= '0;
            req_stale_q <= 1'b0;
            fpc_q       <= RESET_PC;
            fb_rd_q     <= '0;
            fb_wr_q     <= '0;
            fb_count_q  <= '0;
        end else begin
            if (can_issue) begin
                req_valid_q <= 1'b1;
                req_pc_q    <= issue_pc;
                req_stale_q <= 1'b0;
                fpc_q       <= {issue_pc[63:3], 3'b000} + 64'd8;
            end else begin
                if (resp) req_valid_q <= 1'b0;
                if (i_redirect_valid) begin
                    req_stale_q <= 1'b1;
                    fpc_q       <= i_redirect_pc;
                end
            end

            if (i_redirect_valid) begin
                fb_rd_q <= '0;
                fb_wr_q <= '0;
            end else begin
                if (fb_push) begin
                    fb_pc[fb_wr_q]   <= req_pc_q;
                    fb_data[fb_wr_q] <= wb_fetch_dat_i;
                    fb_err[fb_wr_q]  <= wb_fetch_err_i;
                    fb_wr_q          <= ptr_inc(fb_wr_q);
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
endmodule
