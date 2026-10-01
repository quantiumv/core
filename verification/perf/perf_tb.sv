/*
 * perf_tb.sv -- P3.5 CPI baseline testbench (pipelining track plan).
 * Runs ONE kernel image on ONE of two configurations and reports its
 * measured cycle/instret deltas (see perf.h) as a single $display line
 * run_perf.sh parses.
 *
 * CACHE_CFG=0 (default): the SRAM-only harness (testbench/
 *   core_wb4_sram_harness.sv) -- no caches, no UART/CLINT/PLIC. This is
 *   the "FSM baseline" run_perf.sh writes to baseline_fsm.csv.
 * CACHE_CFG=1: design/soc.sv, the real SoC with I$/D$ -- the identical
 *   kernel image works unmodified, since both configurations' RAM
 *   starts at the same address 0x0 (see link.ld's own header).
 *
 * +HEXFILE/+PERF_RESULT_ADDR/+TIMEOUT mirror the exact plusarg
 * conventions the lockstep harness already established (+HEXFILE,
 * +TOHOST_ADDR) -- run_perf.sh resolves PERF_RESULT_ADDR per kernel via
 * `nm`, the same way run_lockstep.sh resolves each ACT4 ELF's tohost.
 *
 * Each generate branch is fully self-contained (readmemh, halt-wait,
 * result readout) rather than referencing a shared `dut` from outside
 * the generate block -- a generate block is its own named scope
 * (g_fsm/g_cache), so a plain top-level `dut` wouldn't resolve either
 * way. Mirrors lockstep_mem.sv's own g_sram_cfg/g_cache_cfg precedent.
 */
`include "perf_common.svh"

module perf_tb #(
    parameter bit CACHE_CFG = 1'b0
);
    string       hex_path;
    logic [31:0] perf_result_addr;
    longint      timeout_cycles;

    initial begin
        if (!$value$plusargs("HEXFILE=%s", hex_path))              hex_path          = "";
        if (!$value$plusargs("PERF_RESULT_ADDR=%h", perf_result_addr)) perf_result_addr = 32'b0;
        if (!$value$plusargs("TIMEOUT=%d", timeout_cycles))        timeout_cycles    = 500000;
    end

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    generate
        if (!CACHE_CFG) begin : g_fsm
            logic halted = 1'b0;

            core_wb4_sram_harness #(.NUM_WORDS(4096)) dut (
                .clk(clk), .rst(rst)
            );

            always @(posedge clk)
                if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;

            `include "halt_wait.sv"

            initial begin
                rst = 1'b1;
                repeat (4) @(posedge clk);
                #1;
                if (hex_path != "") $readmemh(hex_path, dut.sram0.memory);
                @(posedge clk); #1;
                rst = 1'b0;

                wait_halted_or_timeout(timeout_cycles, "kernel never reached EBREAK (fsm)");
                `PERF_REPORT(dut.sram0.memory, perf_result_addr)
                $finish;
            end
        end else begin : g_cache
            logic halted = 1'b0;

            soc dut (.clk(clk), .rst(rst));

            always @(posedge clk)
                if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;

            `include "halt_wait.sv"

            initial begin
                rst = 1'b1;
                repeat (4) @(posedge clk);
                #1;
                if (hex_path != "") $readmemh(hex_path, dut.sram0.memory);
                @(posedge clk); #1;
                rst = 1'b0;

                wait_halted_or_timeout(timeout_cycles, "kernel never reached EBREAK (cache)");
                `PERF_REPORT(dut.sram0.memory, perf_result_addr)
                $finish;
            end
        end
    endgenerate
endmodule
