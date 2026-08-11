// SPDX-License-Identifier: MIT
//
// riscv-formal RVFI wrapper for quantiumv/core (design/core.sv).
// core.sv itself carries native RVFI ports (gated by `ifdef RISCV_FORMAL,
// see its own comment near those ports) -- this wrapper's only job is to
// rename clk/rst to clock/reset, splice `RVFI_CONN into the instantiation,
// and drive the Wishbone slave side (wb_dat_i/wb_ack_i/wb_err_i) as free/
// unconstrained formal inputs, matching every other riscv-formal core
// integration's convention (see cores/nerv/wrapper.sv upstream): the
// "insn" check family verifies architectural correctness of whatever the
// core eventually commits, independent of how many cycles memory took to
// respond, so there is no concrete SRAM model here on purpose.

module rvfi_wrapper (
    input         clock,
    input         reset,
    `RVFI_OUTPUTS
);
    (* keep *) wire [31:0] wb_addr;
    (* keep *) wire [63:0] wb_dat_m2s;
    (* keep *) `rvformal_rand_reg [63:0] wb_dat_s2m;
    (* keep *) wire [7:0]  wb_sel;
    (* keep *) wire        wb_we;
    (* keep *) wire        wb_cyc;
    (* keep *) wire        wb_stb;
    (* keep *) `rvformal_rand_reg wb_ack;
    (* keep *) `rvformal_rand_reg wb_err;

    core uut (
        .clk(clock),
        .rst(reset),

        .wb_addr_o(wb_addr),
        .wb_dat_o(wb_dat_m2s),
        .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel),
        .wb_we_o(wb_we),
        .wb_cyc_o(wb_cyc),
        .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack),
        .wb_err_i(wb_err),

        `RVFI_CONN
    );
endmodule
