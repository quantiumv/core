// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: sim_soc_top
 *
 * Milestone 10b (EBREAK/JTAG staged plan, full-stack OpenOCD integration) --
 * the Verilator top-level wrapping the real, unmodified design/soc.sv for
 * verification/openocd/sim_main.cpp's own remote_bitbang harness. Exists
 * ONLY to override the firmware image design/wb4_sram.sv unconditionally
 * $readmemh's at time 0 (firmware/crt0.hex, the hello-world image) --
 * exactly the same "#1-past-time-0 second $readmemh" convention every
 * other *_toolchain_tb.sv in this project already uses (see
 * testbench/core_priv_toolchain_tb.sv's own header for the fuller
 * rationale), not a new pattern invented for this milestone. Zero other
 * logic -- soc.sv itself is instantiated completely unmodified, which is
 * the whole point of this milestone (pure integration, no new RTL beyond
 * Milestone 10a's already-shipped, already-verified dm.sv/dm_dmi.sv/
 * jtag_tap.sv/soc.sv changes).
 *
 * Run from firmware/ so the relative path below resolves next to the real
 * .hex files -- see run_m10_smoke_test.sh's own orchestration.
 */
module sim_soc_top (
    input  logic clk,
    input  logic rst,
    input  logic jtag_tck,
    input  logic jtag_tms,
    input  logic jtag_tdi,
    output logic jtag_tdo,
    input  logic jtag_trst_n
);

    soc dut (
        .clk(clk), .rst(rst),
        .jtag_tck(jtag_tck), .jtag_tms(jtag_tms), .jtag_tdi(jtag_tdi),
        .jtag_tdo(jtag_tdo), .jtag_trst_n(jtag_trst_n)
    );

    initial begin
        #1; // after wb4_sram.sv's own time-0 init of firmware/crt0.hex
        $readmemh("m10_debug_test.hex", dut.sram0.memory);
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
