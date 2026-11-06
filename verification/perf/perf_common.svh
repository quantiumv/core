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
// QV_REF_AS_CORE the report is empty (and there is no S-mode build: its result is the stack's window).
`ifdef QV_REF_AS_CORE
`define PERF_STACK_REPORT(STACK, MEM_ARRAY, ADDR)
`define PERF_RESULT_AND_STACK(STACK, MEM_ARRAY, ADDR) `PERF_REPORT(MEM_ARRAY, ADDR)
`else
// the monitor, named `stack`, wired to the core's own nets (CORE is the hierarchical path to the core instance)
// (WIN_CSR: the window's CSR, a localparam of the instantiating module)
`define PERF_STACK_INST(CORE, BUSWAIT) \
    perf_stack #(.WIN_CSR(WIN_CSR)) stack ( \
        .clk(clk), .rst(rst), \
        .commit(CORE.commit_now_w), .instr_retired(CORE.c_instr_retired), \
        .head_valid(CORE.head_valid), .head_complete(CORE.head_entry.complete), \
        .head_cls(CORE.head_ctrl.cls), .head_raw(CORE.head_entry.raw), .head_pc(CORE.head_entry.pc), .head_next_pc(CORE.head_entry.next_pc), \
        .head_mispredict(CORE.head_entry.mispredict), \
        .head_serialize(CORE.head_ctrl.serialize), .head_csr_wsup(CORE.head_ctrl.csr_wsup), .head_csr_addr(CORE.head_ctrl.csr_addr), \
        .head_tag(CORE.head_tag), \
        .flush(CORE.flush), .fe_redirect(CORE.fe_redirect_valid), .rob_empty(CORE.rob_empty), \
        .fb_valid(CORE.fb_valid), .iq_valid(CORE.iq_valid), .uop_valid(CORE.uop_valid), .uop_fu(CORE.uop.fu), \
        .issue_fire(CORE.issue_fire), .a_ready(CORE.issue0.a_ready), .b_ready(CORE.issue0.b_ready), .c_ready(CORE.issue0.c_ready), \
        .alloc_ready(CORE.alloc_ready), .lsu_free(CORE.lsu_free), .div_free(CORE.div_free), \
        .wb_valid(CORE.wb_bus.valid), .wb_mispredict(CORE.wb_bus.mispredict), .wb_tag(CORE.wb_bus.tag), \
        .lsu_bus_wait(BUSWAIT), \
        .f_issue(CORE.fetch0.can_issue), .f_issue_pc(CORE.fetch0.issue_pc), .f_xl_on(CORE.fetch_xl_on), \
        .f_xl_req(CORE.f_xl_req), .f_xl_done(CORE.f_xl_done), .f_xl_fault(CORE.f_xl_pf || CORE.f_xl_af), .f_xl_va(CORE.f_xl_va), \
        .f_hold(CORE.fetch_hold), .f_redirect(CORE.fetch_redirect), .f_redirect_ctx(CORE.fetch_redirect_ctx), \
        .sfence(CORE.c_sfence), .in_debug(CORE.dbg_in_debug), \
        .lsu_wait_head(CORE.lsu0.state_q == 2'd1), .lsu_at_head(CORE.lsu0.at_head), \
        .x_req(CORE.x_req), .x_done(CORE.x_done), .x_fault(CORE.x_pf || CORE.x_af) \
    );
`define PERF_STACK_REPORT(STACK, MEM_ARRAY, ADDR) \
    begin \
        longint unsigned _perf_instret_s; \
        _perf_instret_s = MEM_ARRAY[ADDR[31:3] + 1]; \
        STACK.report(_perf_instret_s); \
    end
// the result line and the stack: the kernel's own numbers, or in the S-mode build (SMODE) the window's
`define PERF_RESULT_AND_STACK(STACK, MEM_ARRAY, ADDR) \
    if (SMODE) begin \
        STACK.report_result(); \
        STACK.report(STACK.c_instret); \
    end else begin \
        `PERF_REPORT(MEM_ARRAY, ADDR) \
        `PERF_STACK_REPORT(STACK, MEM_ARRAY, ADDR) \
    end
`endif

`endif
