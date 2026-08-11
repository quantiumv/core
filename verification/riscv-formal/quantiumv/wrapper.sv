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
//
// This file is read via riscv-formal's read_slang frontend (see this
// core's own checks.cfg comment for why: Yosys's built-in Verilog-2005
// frontend can't parse two constructs core.sv/decoder.sv/c_expand.sv
// genuinely need), which runs as its own independent preprocessor pass
// -- it does NOT share macro state with whatever frontend reads the
// riscv-formal-generated per-check glue file, so RVFI_OUTPUTS/RVFI_CONN
// need their own explicit include here rather than relying on some
// other file having already pulled them in -- "defines.sv" is riscv-
// formal's own per-check-generated file (NRET/XLEN/ILEN plus
// `include "rvfi_macros.vh"`), the same one the check-glue file itself
// uses, so this stays automatically in sync with whatever ISA options
// checks.cfg selects rather than duplicating those values here.
`include "defines.sv"

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
