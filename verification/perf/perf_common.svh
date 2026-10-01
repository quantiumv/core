`ifndef QV_PERF_COMMON_SVH
`define QV_PERF_COMMON_SVH

// Reads the two 64-bit result words perf.h's perf_report() wrote
// (cycles, then instret) directly out of a wb4_sram.sv-style word-
// addressed `memory` array, and prints the single PERF_RESULT: line
// run_perf.sh parses. A macro, not a task, so it can be dropped inline
// in either perf_tb.sv generate branch without a cross-scope call --
// each branch is its own named scope (g_fsm/g_cache), so a shared task
// couldn't reach a branch-local `dut` by name anyway.
`define PERF_REPORT(MEM_ARRAY, ADDR) \
    begin \
        longint _perf_cycles, _perf_instret; \
        _perf_cycles  = MEM_ARRAY[ADDR[31:3]]; \
        _perf_instret = MEM_ARRAY[ADDR[31:3] + 1]; \
        $display("PERF_RESULT: cycles=%0d instret=%0d", _perf_cycles, _perf_instret); \
    end

`endif
