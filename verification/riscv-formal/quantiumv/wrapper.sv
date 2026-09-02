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
    // Free/unconstrained -- lets the solver assert the timer-interrupt-pending
    // input on any cycle, same convention as wb_ack/wb_err above and matching
    // riscv-formal's own cores/nerv/wrapper.sv precedent for a free interrupt-
    // pending input (irq, wired the identical way). Without this, i_mtip
    // floats to core.sv's own ANSI default (1'b0) since core uut's own
    // instantiation would otherwise omit it entirely -- meaning
    // interrupt_taken could never fire in ANY generated check, and the
    // real rvfi_intr logic in core.sv would be permanently dead code from
    // this formal model's perspective.
    (* keep *) `rvformal_rand_reg i_mtip;
    // Same reasoning as i_mtip immediately above, applied to Milestone 4's
    // new halt/resume debug-entry inputs: left unconnected (floating to
    // core.sv's own ANSI default 1'b0), debug_halt_req_entry and
    // stepping_q would be provably always-false under BMC, making
    // S_DEBUG_HALTED (via the external-halt path) and interrupt_taken's
    // new debug-halt exclusion guard both permanently dead code from this
    // formal model's perspective. i_debug_resume_req is free too, even
    // though it's a one-cycle pulse architecturally -- an unconstrained
    // rand_reg can still coincidentally read 1 on any given cycle, which
    // is exactly the "could this happen on some cycle" question BMC asks.
    (* keep *) `rvformal_rand_reg i_debug_halt_req;
    (* keep *) `rvformal_rand_reg i_debug_resume_req;

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
        .i_mtip(i_mtip),
        .i_debug_halt_req(i_debug_halt_req),
        .i_debug_resume_req(i_debug_resume_req),

        `RVFI_CONN
    );

// No compressed-instruction-exclusion guard needed here (2026-08-12,
// removed -- see git history for the version that had one). It existed
// only because core.sv's rvfi_insn used to report the C-expanded 32-bit
// EQUIVALENT of a compressed instruction rather than its raw encoding,
// which meant a compressed retiring instruction could accidentally look
// like a real 32-bit opcode to a base-ISA insn_*.v spec model (the
// insn_add_ch0 counterexample this project's README documents). Now that
// rvfi_insn reports the raw 16-bit encoding (zero-extended) per the RVFI
// spec, this is structurally impossible: every base-ISA opcode has
// bits[1:0]==11 by construction (the ISA's own "not compressed" marker),
// which a zero-extended 16-bit value can never satisfy. Confirmed by
// direct test: all 56 isa=rv64i checks pass with this guard fully
// removed, including insn_add_ch0 and the 8 branch/jump checks the guard
// was originally added for.
endmodule
