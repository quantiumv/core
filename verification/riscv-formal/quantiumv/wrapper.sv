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

`ifndef RISCV_FORMAL_ALLOW_COMPRESSED
`ifndef RISCV_FORMAL_CHECK_ill_ch0
    // Base-ISA-only check scope (isa=rv64i/im/ima/imac's non-Zca checks):
    // wb_dat_s2m is otherwise fully free, and the solver is entitled to
    // pick fetched bytes that legitimately decode as a *compressed*
    // instruction (any 16-bit-aligned halfword with bits[1:0] != 2'b11) --
    // this core correctly detects that and advances pc by 2, but the
    // standard riscv-formal insn_*.v spec models always assume ILEN=32
    // non-compressed semantics (spec_pc_wdata = pc_rdata+4
    // unconditionally). Root-caused via a real insn_add_ch0 counterexample
    // (2026-08-11): the solver picked fetch data that happened to also be
    // a valid C2-quadrant compressed encoding, our core correctly used
    // pc+2, the spec model expected pc+4 -- not an RTL bug, a missing
    // wrapper constraint for this check scope. Remove this whole guard
    // once Zca-specific check models are added -- see this dir's README.md.
    //
    // RISCV_FORMAL_CHECK_ill_ch0 exemption (2026-08-12): `ill_ch0` is the
    // one check this guard is actively self-defeating for -- its stock
    // rvfi_ill_check.sv template needs rvfi_insn==0 to be reachable
    // (riscv-formal's own canonical "obviously illegal" test vector), and
    // 0 can only ever arise here via the compressed C.ILLEGAL encoding
    // (16'h0000), which this guard rules out entirely. checks.cfg's
    // [script-sources] passes `-D RISCV_FORMAL_CHECK_@checkch@`, giving
    // every generated check a macro named after its own full instance
    // name (RISCV_FORMAL_CHECK_insn_add_ch0, RISCV_FORMAL_CHECK_ill_ch0,
    // etc.) -- only ill_ch0 defines this specific one, so only it gets
    // the guard lifted.
    always @* begin
        assume (wb_dat_s2m[ 1: 0] == 2'b11);
        assume (wb_dat_s2m[17:16] == 2'b11);
        assume (wb_dat_s2m[33:32] == 2'b11);
        assume (wb_dat_s2m[49:48] == 2'b11);
    end
`endif
`endif
endmodule
