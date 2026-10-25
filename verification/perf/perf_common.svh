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

// The CPI stack (perf_stack.sv) belongs to the pipelined core; the reference has none of the nets it reads, so under
// QV_REF_AS_CORE the report is empty.
`ifdef QV_REF_AS_CORE
`define PERF_STACK_REPORT(STACK, MEM_ARRAY, ADDR)
`else
// the monitor, named `stack`, wired to the core's own nets (CORE is the hierarchical path to the core instance)
`define PERF_STACK_INST(CORE, BUSWAIT) \
    perf_stack stack ( \
        .clk(clk), .rst(rst), \
        .commit(CORE.commit_now_w), .head_valid(CORE.head_valid), .head_complete(CORE.head_entry.complete), \
        .head_cls(CORE.head_ctrl.cls), .head_raw(CORE.head_entry.raw), .head_pc(CORE.head_entry.pc), .head_next_pc(CORE.head_entry.next_pc), \
        .head_mispredict(CORE.head_entry.mispredict), \
        .head_serialize(CORE.head_ctrl.serialize), .head_tag(CORE.head_tag), \
        .flush(CORE.flush), .fe_redirect(CORE.fe_redirect_valid), .rob_empty(CORE.rob_empty), \
        .fb_valid(CORE.fb_valid), .iq_valid(CORE.iq_valid), .uop_valid(CORE.uop_valid), .uop_fu(CORE.uop.fu), \
        .issue_fire(CORE.issue_fire), .a_ready(CORE.issue0.a_ready), .b_ready(CORE.issue0.b_ready), \
        .alloc_ready(CORE.alloc_ready), .lsu_free(CORE.lsu_free), .div_free(CORE.div_free), \
        .wb_valid(CORE.wb_bus.valid), .wb_mispredict(CORE.wb_bus.mispredict), .wb_tag(CORE.wb_bus.tag), \
        .lsu_bus_wait(BUSWAIT) \
    );
`define PERF_STACK_REPORT(STACK, MEM_ARRAY, ADDR) \
    begin \
        longint unsigned _perf_instret_s; \
        _perf_instret_s = MEM_ARRAY[ADDR[31:3] + 1]; \
        STACK.report(_perf_instret_s); \
    end
`endif

`endif
