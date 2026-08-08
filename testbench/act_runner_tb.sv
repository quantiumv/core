// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: act_runner_tb -- generic runner for RISC-V ACT4
 * (riscv-arch-test) self-checking ELFs against this core.
 *
 * Every other testbench in this repo hand-assembles or real-toolchain-
 * builds ONE specific program and hard-codes its expected register/CSR
 * values into the testbench file itself. This one is different in kind:
 * ACT4's tests are *self-checking* -- each generated ELF has its expected
 * results baked in at generation time (computed by the Sail reference
 * model, see verification/riscv-arch-test/quantiumv-rv64im/), and the
 * test's own compiled-in assembly does the comparison at runtime, calling
 * RVMODEL_HALT_PASS or RVMODEL_HALT_FAIL (see
 * verification/riscv-arch-test/quantiumv-rv64im/rvmodel_macros.h). This
 * harness's only job is: load an arbitrary compiled ELF (as hex), run the
 * core to completion, and report which halt macro fired. It carries zero
 * test-specific knowledge -- one compiled testbench binary is reused
 * across every ACT4 test via plusargs, invoked fresh (one `vvp` process
 * per ELF) by an external driver script that iterates the generated
 * `elfs/` directory.
 *
 * How pass/fail is actually detected: rvmodel_macros.h's RVMODEL_HALT_PASS/
 * FAIL macros write a marker word (1=pass, 3=fail) to a `tohost` symbol
 * -- the classic riscv-tests/HTIF convention, present purely so the Sail
 * reference model's OWN signature-computation run terminates the same way
 * it always does -- and then execute `ebreak`, this core's one real
 * simulation-halt mechanism (design/core.sv: permanent `halted` latch).
 * This harness waits on `halted` (same convention every other testbench
 * uses) and then reads the marker word straight out of SRAM. `tohost`'s
 * address moves per-test (its `.text.rvmodel` section's size varies with
 * how much test code preceded it), so it's supplied via +TOHOST_ADDR
 * rather than assumed -- the driver script extracts it per-ELF via
 * `riscv64-unknown-elf-nm`.
 *
 * Required plusargs (all consumed via $value$plusargs, see initial block):
 *   +HEXFILE=<path>       -- $readmemh-format hex image (objcopy -O verilog
 *                             --verilog-data-width=8, same convention every
 *                             hex image under firmware/ in this repo already uses).
 *   +TOHOST_ADDR=<hex>    -- byte address of the `tohost` symbol, no `0x`
 *                             prefix (e.g. +TOHOST_ADDR=1234).
 * Optional:
 *   +TIMEOUT=<decimal>    -- cycle budget before declaring TIMEOUT;
 *                             defaults to 1000000. ACT4 tests can pack many
 *                             self-checking subcases into one file -- e.g. the
 *                             M-extension divide-family tests alone retire
 *                             ~490k cycles on this core's genuinely multi-cycle
 *                             (~64 cycle) divider -- so this defaults well
 *                             above every hand-written
 *                             testbench's own TIMEOUT_CYCLES_LARGE (3000).
 *
 * Output contract (parsed by the driver script, not by a human): exactly
 * one of these on its own line, before $finish:
 *   ACT_RESULT: PASS
 *   ACT_RESULT: FAIL
 *   ACT_RESULT: UNKNOWN (tohost=0x...)   -- halted without a recognized
 *                                           pass(1)/fail(3) marker; a real
 *                                           anomaly (bad tohost address, a
 *                                           DUT bug that reaches ebreak by
 *                                           some other path) worth looking
 *                                           at by hand, never a silent pass.
 *   TIMEOUT: ...                          -- emitted by halt_wait.sv itself
 *                                            if `halted` never asserts.
 *
 * NUM_WORDS is sized for the largest self-checking ELF actually observed
 * from `make` against quantiumv-rv64im.yaml (see that generation's log) --
 * comfortably rounded up, not the tightest fit; bump it here if a future,
 * larger extension's tests overflow it (iverilog/vvp will report a
 * $readmemh range error if so, not a silent truncation).
 *
 * No UART/console support: RVMODEL_IO_WRITE_STR is a no-op in
 * rvmodel_macros.h (this harness has no UART wired in, matching
 * core_wb4_sram_harness.sv's topology), so ACT4's normal on-failure
 * diagnostic printing (failing PC/instruction/register/expected/actual)
 * is not available here -- FAIL only tells you *that* a test failed, not
 * why. Diagnosing a real failure means reading that test's .elf.objdump
 * by hand (see the Troubleshooting section of riscv-arch-test's README).
 */
module act_runner_tb;

    localparam int NUM_WORDS = 131072; // 1 MiB -- see header comment

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    core dut (
        .clk(clk), .rst(rst),
        .wb_addr_o(wb_addr), .wb_dat_o(wb_dat_m2s), .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack), .wb_err_i(wb_err)
    );

    wb4_sram #(.num_words(NUM_WORDS)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .ack_o(wb_ack), .err_o(wb_err), .cyc_i(wb_cyc), .stb_i(wb_stb), .we_i(wb_we)
    );

    wire halted = dut.halted;
    `include "halt_wait.sv"

    initial begin
        string hex_path;
        logic [31:0] tohost_addr;
        int timeout_cycles;
        logic [63:0] tohost_word;

        if (!$value$plusargs("HEXFILE=%s", hex_path)) begin
            $display("ACT_RESULT: ERROR -- +HEXFILE=<path> not provided");
            $finish;
        end
        if (!$value$plusargs("TOHOST_ADDR=%h", tohost_addr)) begin
            $display("ACT_RESULT: ERROR -- +TOHOST_ADDR=<hex> not provided");
            $finish;
        end
        if (!$value$plusargs("TIMEOUT=%d", timeout_cycles)) begin
            timeout_cycles = 1000000;
        end

        #1; // see header comment on core_priv_toolchain_tb.sv: run after wb4_sram's own time-0 init of crt0.hex
        $readmemh(hex_path, sram0.memory);

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(timeout_cycles, "core never halted -- missing ebreak in the generated ELF, or a real hang");

        tohost_word = sram0.memory[tohost_addr[31:3]];
        if (tohost_word == 64'd1)
            $display("ACT_RESULT: PASS");
        else if (tohost_word == 64'd3)
            $display("ACT_RESULT: FAIL");
        else
            $display("ACT_RESULT: UNKNOWN (tohost=0x%016h)", tohost_word);

        $finish;
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
