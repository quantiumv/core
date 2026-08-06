// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Shared task: wb_cycle -- one Wishbone classic bus transaction
 *
 * `include-able, not a module -- pulled in textually via `include
 * "wb_driver.sv" inside a caller's own module body, so wb_cycle resolves
 * the including module's own local signals through ordinary Verilog
 * scoping, no arguments needed for that part. This is the only mechanism
 * confirmed to work for sharing testbench logic in this Icarus build: SV
 * interfaces fail to parse here, and `ref` task arguments aren't supported
 * ("sorry: Reference ports not supported yet."), so a shared task can't
 * take a caller's signals by reference -- it has to reach them by name,
 * the same way this file reaches the required-signal contract below.
 * Resolved via a bare filename in the `include plus an explicit
 * -I testbench flag on the iverilog command line -- Icarus does NOT
 * resolve `include relative to the including file, only via -I.
 *
 * Required signal contract -- the including module must declare all of
 * these, with these exact names, before the `include line:
 *   clk            -- the shared clock
 *   addr   [31:0]  -- Wishbone address; driven by wb_cycle
 *   dat_i  [63:0]  -- data TO the slave (write data); driven by wb_cycle
 *   dat_o  [63:0]  -- data FROM the slave (read data); wb_cycle never
 *                     touches this signal -- the caller reads it directly
 *                     off the DUT after wb_cycle returns
 *   sel    [7:0]   -- byte-lane select; driven by wb_cycle
 *   we             -- write enable; driven by wb_cycle
 *   cyc, stb       -- bus cycle/strobe; driven by wb_cycle
 *   ack, err       -- slave response; only read by wb_cycle, never driven
 *
 * The historical bug this fix prevents: ack_o (and err_o) are updated via
 * <= inside the DUT's clocked block, so the new value only becomes visible
 * in the NBA region AFTER the posedge's active region finishes. Checking
 * ack immediately upon resuming from @(posedge clk) reads its PRE-edge
 * value, one edge stale -- which makes a naive wait loop exit one edge
 * late, leaving cyc/stb asserted for an extra edge and causing the DUT to
 * process the same transaction a second time. This was first found as a
 * real bug during design/uart_tx_tb.sv's development: a duplicated UART
 * character in the captured tx_history, traced to exactly this stale-ack
 * read, and fixed there with a #1 settle after every @(posedge clk) before
 * checking ack (silently harmless for an idempotent memory read/write, but
 * not for a side-effecting peripheral like a UART). design/wb4_sram_tb.sv
 * independently carries the identical fix -- same task, same #1, same
 * reasoning -- copy-pasted rather than shared. This file is that fix,
 * written once.
 *
 * The wait loop below is `!ack && !err`, not just `!ack` -- a deliberate
 * generalization over the original 3 copies (design/uart_tx_tb.sv,
 * design/wb4_sram_tb.sv, design/wb_addr_decoder_tb.sv), which all only
 * looped on !ack and would hang forever waiting for an ack that will never
 * come on an error response. design/wb4_sram_tb.sv's own out-of-range test
 * already had to hand-write this exact `!ack && !err` loop inline, right
 * next to its own copy of wb_cycle that lacked it, specifically so that
 * test could terminate. Folding the fix into the shared task means every
 * caller gets err-handling for free, not just the one call site that
 * happened to need it.
 *
 * CSR-port driving (design/csr_file_tb.sv's read_csr/write_csr, including
 * the real #0-settle fast-sweep variant design/csr_file_random_tb.sv
 * needs for rapid same-timestamp sweeps against a shadow model) is
 * deliberately NOT folded into this file: it's a different protocol
 * entirely (no cyc/stb/ack at all), there are only 2 current consumers,
 * and csr_file_random_tb.sv's own header comment already documents a
 * deliberate decision not to share that scaffold. Revisit only once a
 * second real consumer needs it.
 */
task automatic wb_cycle(logic [31:0] a, logic [63:0] d, logic [7:0] s, logic w);
    @(negedge clk);
    addr = a; dat_i = d; sel = s; we = w; cyc = 1; stb = 1;
    @(posedge clk); #1;
    while (!ack && !err) begin
        @(posedge clk); #1;
    end
    cyc = 0; stb = 0;
endtask


/* ------------------------------------------------------------------------- */


/* End of file. */
