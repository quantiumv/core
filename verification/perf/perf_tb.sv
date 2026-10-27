/*
 * perf_tb.sv -- P3.5 CPI baseline testbench (pipelining track plan).
 * Runs ONE kernel image on ONE of two configurations and reports its
 * measured cycle/instret deltas (see perf.h) as a single $display line
 * run_perf.sh parses.
 *
 * CACHE_CFG=0 (default): the SRAM-only harness (testbench/
 *   core_wb4_sram_harness.sv) -- no caches, no UART/CLINT/PLIC. This is
 *   the baseline run_perf.sh writes to baseline_<core>.csv.
 * CACHE_CFG=1: design/soc.sv, the real SoC with I$/D$ -- the identical
 *   kernel image works unmodified, since both configurations' RAM
 *   starts at the same address 0x0 (see link.ld's own header).
 *
 * +HEXFILE/+PERF_RESULT_ADDR/+TIMEOUT mirror the exact plusarg
 * conventions the lockstep harness already established (+HEXFILE,
 * +TOHOST_ADDR) -- run_perf.sh resolves PERF_RESULT_ADDR per kernel via
 * `nm`, the same way run_lockstep.sh resolves each ACT4 ELF's tohost.
 *
 * SMODE=1 (the S-mode build, crt0_s.s): the kernel runs in S under Sv39 and
 *   cannot read mcycle/minstret, so the result is perf_stack's own window
 *   (cycles and retirements between the two sscratch markers of perf.h);
 *   the flat-SRAM harness gets 64 KB (link_s.ld). Pipelined core only.
 *
 * Each generate branch is fully self-contained (readmemh, halt-wait,
 * result readout) rather than referencing a shared `dut` from outside
 * the generate block -- a generate block is its own named scope
 * (g_fsm/g_cache), so a plain top-level `dut` wouldn't resolve either
 * way. Mirrors lockstep_mem.sv's own g_sram_cfg/g_cache_cfg precedent.
 */
`include "perf_common.svh"

module perf_tb #(
    parameter bit CACHE_CFG = 1'b0,
    parameter bit SMODE     = 1'b0
);
    localparam logic [11:0] WIN_CSR = SMODE ? 12'h140 : 12'hB00;     // the window markers' CSR (perf_stack)
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

            core_wb4_sram_harness #(.NUM_WORDS(SMODE ? 8192 : 4096)) dut (
                .clk(clk), .rst(rst)
            );

`ifndef QV_REF_AS_CORE
            // the LSU's request waits for the arbiter while fetch holds the shared SRAM
            `PERF_STACK_INST(dut.core0, (dut.wbm_cyc && !dut.fetch_mem_arb0.grant))
`endif

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
                `PERF_RESULT_AND_STACK(stack, dut.sram0.memory, perf_result_addr)
                $finish;
            end
        end else begin : g_cache
            logic halted = 1'b0;

            soc dut (.clk(clk), .rst(rst));

`ifndef QV_REF_AS_CORE
            `PERF_STACK_INST(dut.core0, 1'b0)
`endif

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
                `PERF_RESULT_AND_STACK(stack, dut.sram0.memory, perf_result_addr)
                $finish;
            end
        end
    endgenerate
endmodule
