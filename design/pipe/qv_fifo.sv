// SPDX-License-Identifier: MIT

/*
 * qv_fifo -- the instruction queue: two-wide push, one-wide pop.
 *
 * Width-generic over plain bit vectors rather than a struct-typed
 * parameter (callers pass $bits(qv_pkg::fe_instr_t) and cast at the
 * boundary) -- the portable choice across iverilog, Verilator and
 * yosys-slang. Storage is only ever read or written a whole element at a
 * time; iverilog crashes elaborating `array[i].field` on an array of
 * packed structs.
 *
 * Contract: push1 only with push0, and only while o_push_ready (room for
 * two). A pop while empty is ignored. DEPTH must be a power of two
 * (pointers wrap naturally).
 */
module qv_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 4
) (
    input  logic             clk,
    input  logic             rst,
    input  logic             i_flush,

    input  logic             i_push0_valid,
    input  logic [WIDTH-1:0] i_push0_data,
    input  logic             i_push1_valid,
    input  logic [WIDTH-1:0] i_push1_data,
    output logic             o_push_ready,

    output logic             o_head_valid,
    output logic [WIDTH-1:0] o_head_data,
    input  logic             i_pop
);
    localparam int PTR_W = $clog2(DEPTH);
    localparam int CNT_W = $clog2(DEPTH + 1);

    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [PTR_W-1:0] rd_q, wr_q;
    logic [CNT_W-1:0] count_q;

    wire pop = i_pop && (count_q != '0);
    wire [CNT_W-1:0] n_push = CNT_W'(i_push0_valid) + CNT_W'(i_push1_valid);

    assign o_push_ready = (count_q <= CNT_W'(DEPTH - 2));
    assign o_head_valid = (count_q != '0);
    assign o_head_data  = mem[rd_q];

    always_ff @(posedge clk) begin
        if (rst || i_flush) begin
            rd_q    <= '0;
            wr_q    <= '0;
            count_q <= '0;
        end else begin
            if (i_push0_valid) mem[wr_q] <= i_push0_data;
            if (i_push1_valid) mem[wr_q + PTR_W'(1)] <= i_push1_data;
            wr_q    <= wr_q + PTR_W'(n_push);
            if (pop) rd_q <= rd_q + PTR_W'(1);
            count_q <= count_q + n_push - CNT_W'(pop);
        end
    end
endmodule
