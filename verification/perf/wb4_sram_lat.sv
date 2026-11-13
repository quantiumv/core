// SPDX-License-Identifier: MIT

/*
 * wb4_sram_lat -- perf only (OX.0): design/wb4_sram.sv with a memory latency, for measuring what memory-level
 * parallelism buys. A drop-in: the same module name, ports and `memory` array (perf_tb's $readmemh and its result
 * readout work unchanged); run_perf.sh --memlat L[,B[,W]] swaps it in for design/wb4_sram.sv in the cache
 * configuration only (in the flat-SRAM harness it would slow every fetch).
 *
 *   +MEMLAT_L=n  cycles from a read request to its ack (the plain wb4_sram answers in 1)
 *   +MEMLAT_B=n  ... for a read of the next dword of the same 32-byte line that follows the previous read's ack at
 *                once (a refill's later beats: burst-like), default L
 *   +MEMLAT_W=n  ... for a write, default L
 *
 * Still classic Wishbone with one transaction at a time: a request is latched when it is presented and the slave is
 * idle, answered n cycles later, and the master holds it until then (every master here does). With every latency at
 * 1 it answers exactly as wb4_sram does: the cycle after the request.
 */
module wb4_sram #(
    parameter num_words = 4096
) (
    input logic clk,
    input logic rst,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] addr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,
    output logic ack_o,
    output logic err_o,
    input logic cyc_i,
    input logic stb_i,
    input logic we_i
);
    reg [63:0] memory [0:(num_words - 1)];
    localparam ADDR_WIDTH = $clog2(num_words);

    int lat_l, lat_b, lat_w;
    integer init_i;
    initial begin
        if (!$value$plusargs("MEMLAT_L=%d", lat_l)) lat_l = 1;
        if (!$value$plusargs("MEMLAT_B=%d", lat_b)) lat_b = lat_l;
        if (!$value$plusargs("MEMLAT_W=%d", lat_w)) lat_w = lat_l;
        if (lat_l < 1) lat_l = 1;
        if (lat_b < 1) lat_b = 1;
        if (lat_w < 1) lat_w = 1;
        for (init_i = 0; init_i < num_words; init_i = init_i + 1)
            memory[init_i] = '0;
        $readmemh("../firmware/crt0.hex", memory);
    end

    logic        busy_q;
    int          cnt_q;
    logic [31:0] a_q;
    logic [63:0] d_q;
    logic [7:0]  s_q;
    logic        we_q;
    logic [31:0] last_rd_q;         // the last read's address, and how many cycles ago its ack was (2 at most)
    int          rd_win_q;

    // a request is taken whenever it is presented to an idle slave, as wb4_sram does (it re-samples every cycle);
    // the masters here drop cyc in their ack cycle, so nothing is taken twice
    wire req = cyc_i && stb_i && !busy_q;
    wire seq = !we_i && (rd_win_q > 0) && (addr_i[31:5] == last_rd_q[31:5]) && (addr_i[4:3] == last_rd_q[4:3] + 2'd1);

    always @(posedge clk) begin
        if (rst) begin
            ack_o <= 1'b0; err_o <= 1'b0; dat_o <= 64'b0;
            busy_q <= 1'b0; cnt_q <= 0; rd_win_q <= 0; last_rd_q <= '0;
        end else begin
            ack_o <= 1'b0;
            err_o <= 1'b0;
            if (rd_win_q > 0) rd_win_q <= rd_win_q - 1;
            if (req) begin
                busy_q <= 1'b1;
                cnt_q  <= (we_i ? lat_w : seq ? lat_b : lat_l) - 1;
                a_q <= addr_i; d_q <= dat_i; s_q <= sel_i; we_q <= we_i;
            end
            // answer: in the cycle after the request when the latency is 1, else when the count runs out
            if ((req && ((we_i ? lat_w : seq ? lat_b : lat_l) == 1)) || (busy_q && cnt_q <= 1 && !req)) begin : answer
                logic [31:0] a; logic [63:0] d; logic [7:0] s; logic w;
                if (req) begin a = addr_i; d = dat_i; s = sel_i; w = we_i; end
                else     begin a = a_q;    d = d_q;    s = s_q;    w = we_q; end
                busy_q <= 1'b0;
                if (a[31:ADDR_WIDTH+3] == 0) begin
                    if (w) begin
                        for (int lane = 0; lane < 8; lane = lane + 1)
                            if (s[lane]) memory[a[ADDR_WIDTH+2:3]][(8*lane) +: 8] <= d[(8*lane) +: 8];
                    end else begin
                        dat_o <= memory[a[ADDR_WIDTH+2:3]];
                        last_rd_q <= a;
                        rd_win_q <= 2;
                    end
                    ack_o <= 1'b1;
                end else begin
                    err_o <= 1'b1;
                end
            end else if (busy_q) begin
                cnt_q <= cnt_q - 1;
            end
        end
    end
endmodule
