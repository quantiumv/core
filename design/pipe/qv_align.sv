// SPDX-License-Identifier: MIT

/*
 * qv_align -- turns the fetched dword stream into instructions (RVC-aware).
 *
 * A dword holds four halfwords. A halfword whose low two bits aren't 11
 * is a whole 16-bit (RVC) instruction; otherwise it's the low half of a
 * 32-bit one, whose high half is the next halfword -- possibly the first
 * halfword of the next dword (a "crossing" instruction).
 *
 * Up to two instructions leave per cycle, so a dword of four RVC
 * instructions takes two cycles; the fetch buffer is popped once its
 * last halfword is used. State between cycles:
 *   - the halfword offset reached within the head dword (mid_q/off_q);
 *     a fresh dword starts at its pc's halfword (pc[2:1] -- nonzero only
 *     for the first dword after a redirect)
 *   - the low half and pc of a 32-bit instruction that crosses into the
 *     next dword (pend_q); the head dword is then always that next dword,
 *     because a redirect flushes this state along with the fetch buffer
 *
 * A dword that came back with a bus error yields one instruction marked
 * as an instruction access fault (cause 1) at the next pc -- the one
 * whose bytes start in, or cross into, that dword (xcpt_hi for the
 * latter) -- and is dropped. Nothing after it matters: that instruction
 * traps at commit and everything younger is flushed.
 *
 * Instructions are emitted only when the IQ has room for two.
 */
module qv_align (
    input  logic              clk,
    input  logic              rst,
    input  logic              i_flush,

    input  logic              i_buf_valid,
    // bit 0 is always 0: instructions are 2-byte aligned
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]       i_buf_pc,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0]       i_buf_data,
    input  logic              i_buf_err,
    output logic              o_buf_pop,

    output logic              o_push0_valid,
    output qv_pkg::fe_instr_t o_push0_data,
    output logic              o_push1_valid,
    output qv_pkg::fe_instr_t o_push1_data,
    input  logic              i_push_ready
);
    import qv_pkg::*;

    logic        mid_q;
    logic [1:0]  off_q;
    logic        pend_q;
    logic [15:0] pend_hw_q;
    logic [63:0] pend_pc_q;

    wire [63:0] base  = {i_buf_pc[63:3], 3'b000};
    wire [1:0]  start = mid_q ? off_q : i_buf_pc[2:1];
    wire        go    = i_buf_valid && i_push_ready && !i_flush;

    function automatic logic [15:0] hw(input logic [63:0] d, input logic [1:0] i);
        case (i)
            2'd0:    hw = d[15:0];
            2'd1:    hw = d[31:16];
            2'd2:    hw = d[47:32];
            default: hw = d[63:48];
        endcase
    endfunction

    function automatic fe_instr_t mk(input logic [63:0] pc, input logic [31:0] raw, input logic rvc);
        mk     = '0;
        mk.pc  = pc;
        mk.raw = raw;
        mk.rvc = rvc;
    endfunction

    logic [2:0]  cur;            // next halfword of the head dword, 4 = used up
    logic        stash;
    logic [15:0] stash_hw;
    logic [15:0] h;

    always_comb begin
        o_push0_valid = 1'b0;
        o_push1_valid = 1'b0;
        o_push0_data  = '0;
        o_push1_data  = '0;
        stash         = 1'b0;
        stash_hw      = '0;
        cur           = {1'b0, start};
        h             = '0;

        if (go && i_buf_err) begin
            o_push0_valid = 1'b1;
            o_push0_data  = mk(pend_q ? pend_pc_q : base + {61'b0, start, 1'b0}, 32'b0, 1'b0);
            o_push0_data.xcpt       = 1'b1;
            o_push0_data.xcpt_cause = 4'd1;
            o_push0_data.xcpt_hi    = pend_q;
            cur = 3'd4;
        end else if (go) begin
            // slot 0: finish a crossing instruction, or start at cur
            if (pend_q) begin
                o_push0_valid = 1'b1;
                o_push0_data  = mk(pend_pc_q, {hw(i_buf_data, 2'd0), pend_hw_q}, 1'b0);
                cur = 3'd1;
            end else begin
                h = hw(i_buf_data, cur[1:0]);
                if (h[1:0] != 2'b11) begin
                    o_push0_valid = 1'b1;
                    o_push0_data  = mk(base + {61'b0, cur[1:0], 1'b0}, {16'b0, h}, 1'b1);
                    cur = cur + 3'd1;
                end else if (cur == 3'd3) begin
                    stash    = 1'b1;
                    stash_hw = h;
                    cur      = 3'd4;
                end else begin
                    o_push0_valid = 1'b1;
                    o_push0_data  = mk(base + {61'b0, cur[1:0], 1'b0}, {hw(i_buf_data, cur[1:0] + 2'd1), h}, 1'b0);
                    cur = cur + 3'd2;
                end
            end
            // slot 1: one more, if this dword has any left
            if (o_push0_valid && cur != 3'd4) begin
                h = hw(i_buf_data, cur[1:0]);
                if (h[1:0] != 2'b11) begin
                    o_push1_valid = 1'b1;
                    o_push1_data  = mk(base + {61'b0, cur[1:0], 1'b0}, {16'b0, h}, 1'b1);
                    cur = cur + 3'd1;
                end else if (cur == 3'd3) begin
                    stash    = 1'b1;
                    stash_hw = h;
                    cur      = 3'd4;
                end else begin
                    o_push1_valid = 1'b1;
                    o_push1_data  = mk(base + {61'b0, cur[1:0], 1'b0}, {hw(i_buf_data, cur[1:0] + 2'd1), h}, 1'b0);
                    cur = cur + 3'd2;
                end
            end
        end
    end

    assign o_buf_pop = go && (cur == 3'd4);

    always_ff @(posedge clk) begin
        if (rst || i_flush) begin
            mid_q  <= 1'b0;
            pend_q <= 1'b0;
        end else if (go) begin
            mid_q  <= (cur != 3'd4);
            off_q  <= cur[1:0];
            pend_q <= stash;
            if (stash) begin
                pend_hw_q <= stash_hw;
                pend_pc_q <= base + 64'd6;
            end
        end
    end
endmodule
