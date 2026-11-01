// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, the load/store queue's early accesses (O2a), end to end, with the order of the memory port's
 * accesses recorded. Its own harness: fetch from an ideal port, the memory port on a slave with DW wait states (so an
 * access stays on the bus long enough to be seen), one memory of 8 KiB; the RAM window is all of it, 0x2000 and up
 * answer with an error. Code at 0, a trap handler at 0x600, data at 0x1000 (x1).
 *
 * Each run puts a DIV at the ROB head first (66 cycles with nothing retiring), so what goes before the head shows up
 * on the bus before the DIV retires:
 *   A  a load from another dword goes early; a store is posted early; a load of the store's own dword reads memory
 *      only after the store's write (it waits while the store is posted and not retired, then while it is buffered)
 *   B  a load behind a serializing CSR write, and one behind a FENCE r,r, reach the bus only after that retires
 *   E  a load and a store outside the RAM window reach the bus only at the head (and fault there, precisely)
 *   F  the wrong path of a branch that commit redirects: a RAM load on it goes early, but a load the PMP denies and a
 *      load outside the window never reach the bus at all
 *   G  a load behind an AMO, and one behind an LR/SC pair, reach the bus only after the atomic's write
 *   C  an interrupt taken while an early load is on the bus: the load is drained and done again, the values are right
 *   D  a halt taken while an early load is on the bus: the hart shows as halted (o_debug_mode) only once the port is
 *      quiet; after the resume the program finishes with the right values
 */
module core_lsq_tb;
    // the build has early accesses (the queue and QV_PIPE_LSQ_EARLY; core.sv defines both knobs). Without them the
    // runs check only what holds either way: values, order, the window, the wrong path; C and D are skipped.
    localparam bit EARLY_ON = (`QV_PIPE_LSQ_DEPTH != 0) && (`QV_PIPE_LSQ_EARLY != 0);

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    // ---------------- the harness ----------------
    localparam int WORDS = 1024;                      // 8 KiB
    logic [63:0] mem [0:WORDS-1];

    logic [31:0] f_addr, m_addr;
    logic        f_cyc, f_stb, m_cyc, m_stb, m_we, m_lock, icache_flush;
    logic [63:0] f_dat, m_dat_o, m_dat_i;
    logic [7:0]  m_sel;
    logic        f_ack = 1'b0, f_err = 1'b0, m_ack = 1'b0, m_err = 1'b0;
    logic        mtip = 1'b0, halt_req = 1'b0, resume_req = 1'b0, debug_mode;

    core #(.PMA_RAM_SIZE(64'h2000)) core0 (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(f_addr), .wb_fetch_cyc_o(f_cyc), .wb_fetch_stb_o(f_stb),
        .wb_fetch_dat_i(f_dat), .wb_fetch_ack_i(f_ack), .wb_fetch_err_i(f_err),
        .wb_mem_addr_o(m_addr), .wb_mem_dat_o(m_dat_o), .wb_mem_dat_i(m_dat_i),
        .wb_mem_sel_o(m_sel), .wb_mem_we_o(m_we), .wb_mem_cyc_o(m_cyc), .wb_mem_stb_o(m_stb),
        .wb_mem_ack_i(m_ack), .wb_mem_err_i(m_err), .wb_mem_lock_o(m_lock),
        .icache_flush_o(icache_flush),
        .i_mtip(mtip), .i_debug_halt_req(halt_req), .i_debug_resume_req(resume_req), .o_debug_mode(debug_mode)
    );

    // fetch: answered the cycle after a request, one at a time
    always @(posedge clk) begin
        f_ack <= 1'b0; f_err <= 1'b0;
        if (!rst && f_cyc && f_stb && !f_ack && !f_err) begin
            if (f_addr >= 32'h2000) f_err <= 1'b1;
            else begin f_ack <= 1'b1; f_dat <= mem[f_addr[12:3]]; end
        end
    end

    // the memory port: DW wait states; every response is logged with its cycle
    int          DW = 2;
    int          cyc_n = 0;
    always @(posedge clk) cyc_n <= cyc_n + 1;
    logic        m_busy = 1'b0;
    int          m_left;
    logic [31:0] h_addr; logic [63:0] h_dat; logic [7:0] h_sel; logic h_we;
    int          log_cyc [$]; logic [31:0] log_addr [$]; logic log_we [$]; logic log_err [$];
    always @(posedge clk) begin
        m_ack <= 1'b0; m_err <= 1'b0;
        if (rst) m_busy <= 1'b0;
        else if (!m_busy && m_cyc && m_stb) begin
            m_busy <= 1'b1; m_left <= DW;
            h_addr <= m_addr; h_dat <= m_dat_o; h_sel <= m_sel; h_we <= m_we;
        end else if (m_busy) begin
            if (m_left > 0) m_left <= m_left - 1;
            else begin
                m_busy <= 1'b0;
                log_cyc.push_back(cyc_n); log_addr.push_back(h_addr); log_we.push_back(h_we);
                log_err.push_back(h_addr >= 32'h2000);
                if (h_addr >= 32'h2000) m_err <= 1'b1;
                else begin
                    m_ack <= 1'b1;
                    if (h_we)
                        for (int i = 0; i < 8; i++)
                            if (h_sel[i]) mem[h_addr[12:3]][8*i +: 8] <= h_dat[8*i +: 8];
                    m_dat_i <= mem[h_addr[12:3]];
                end
            end
        end
    end

    // the cycle of the first access (read or write) to a dword, -1 if none
    function automatic int first_acc(input logic [31:0] a, input logic we);
        for (int i = 0; i < log_cyc.size(); i++)
            if (log_addr[i] == {a[31:3], 3'b000} && log_we[i] == we) return log_cyc[i];
        return -1;
    endfunction
    function automatic int any_acc(input logic [31:0] a);
        for (int i = 0; i < log_cyc.size(); i++)
            if (log_addr[i] == {a[31:3], 3'b000}) return 1;
        return 0;
    endfunction

    // retirements: the cycle the instruction at a pc (code is below 0x800) first retires, -1 if never
    int ret_pc_cyc [0:511];
    always @(posedge clk)
        if (!rst && core0.commit_now_w && core0.c_pc_rdata < 64'h800 && ret_pc_cyc[core0.c_pc_rdata[10:2]] < 0)
            ret_pc_cyc[core0.c_pc_rdata[10:2]] = cyc_n;
    function automatic int t_ret(input int pc); return ret_pc_cyc[pc[10:2]]; endfunction

    // early accesses: the cycle of the first post before the head
    int early_post_cyc = -1, early_ld_n = 0;
    always @(posedge clk) if (!rst) begin
        if (core0.lsu0.post_done && !core0.lsu0.at_head && early_post_cyc < 0) early_post_cyc = cyc_n;
        if (core0.lsu0.start && !core0.lsu0.at_head) early_ld_n = early_ld_n + 1;
    end

    logic halted = 1'b0;
    always @(posedge clk) if (core0.trap_taken && core0.is_ebreak) halted <= 1'b1;

    // ---------------- programs ----------------
    logic [31:0] prog [0:1023];
    int          n;
    task automatic emit(input logic [31:0] w); prog[n] = w; n++; endtask
    function automatic int here(); return n * 4; endfunction

    localparam logic [63:0] K1 = 64'h8899_AABB_CCDD_EEFF;
    function automatic logic [63:0] init_word(input int i); return {32'hD00D_0000 + 32'(i), 32'hFEED_0000 + 32'(i)}; endfunction

    task automatic load_image();
        for (int i = 0; i < WORDS; i++) mem[i] = init_word(i);
        for (int i = 0; i < n; i += 2)
            mem[i / 2] = {(i + 1 < n) ? prog[i + 1] : 32'h0000_0013, prog[i]};
        mem[(32'h1700) >> 3] = K1;
    endtask

    function automatic logic [31:0] i_(input int imm, input int rs1, input logic [2:0] f3, input int rd, input logic [6:0] opc);
        return encode_i(imm, rs1[4:0], f3, rd[4:0], opc);
    endfunction
    function automatic logic [31:0] st_(input int imm, input int rs2, input int rs1, input logic [2:0] f3);
        return encode_s(imm, rs2[4:0], rs1[4:0], f3, `OPC_STORE);
    endfunction
    function automatic logic [31:0] ld_(input int imm, input int rs1, input logic [2:0] f3, input int rd);
        return encode_i(imm, rs1[4:0], f3, rd[4:0], `OPC_LOAD);
    endfunction
    function automatic logic [31:0] div_(input int rd, input int rs1, input int rs2);
        return encode_r(7'b0000001, rs2[4:0], rs1[4:0], 3'b100, rd[4:0], `OPC_OP);
    endfunction
    localparam logic [31:0] NOP = 32'h0000_0013, EBREAK = 32'h0010_0073;

    // x1 = 0x1000 (data), x2 = K1, x4 = 1, x6 = -1, x7 = 3 (x6 / x7 is a 64-bit divide), mtvec = 0x600
    task automatic prologue();
        n = 0;
        emit(encode_u(20'd1, 5'd1, `OPC_LUI));                          // lui  x1, 1
        emit(ld_(32'h700, 1, 3'b011, 2));                               // ld   x2, 0x700(x1)
        emit(i_(-1, 0, 3'b000, 6, `OPC_OP_IMM));
        emit(i_(3, 0, 3'b000, 7, `OPC_OP_IMM));
        emit(i_(1, 0, 3'b000, 4, `OPC_OP_IMM));
        emit(i_(32'h600, 0, 3'b000, 29, `OPC_OP_IMM));
        emit(encode_csr(`CSR_MTVEC, 5'd29, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM));
    endtask
    // the handler at 0x600: an interrupt counts in x30; an exception leaves mcause in x26, mepc in x27 and skips it
    task automatic handler();
        while (n < 32'h600 / 4) emit(NOP);
        emit(encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd25, `OPC_SYSTEM));          // csrr x25, mcause
        emit(encode_b(6 * 4, 5'd0, 5'd25, 3'b100, `OPC_BRANCH));                         // blt  x25, x0, irq
        emit(encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd27, `OPC_SYSTEM));            // csrr x27, mepc
        emit(i_(4, 27, 3'b000, 28, `OPC_OP_IMM));                                       // addi x28, x27, 4
        emit(encode_csr(`CSR_MEPC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM));            // csrw mepc, x28
        emit(i_(0, 25, 3'b000, 26, `OPC_OP_IMM));                                       // mv   x26, x25
        emit(`INSTR_HEX_MRET);
        emit(i_(1, 30, 3'b000, 30, `OPC_OP_IMM));                                       // irq: addi x30, x30, 1
        emit(`INSTR_HEX_MRET);
    endtask

    task automatic run(input int limit, input string what);
        rst = 1'b1; halted = 1'b0;
        log_cyc.delete(); log_addr.delete(); log_we.delete(); log_err.delete();
        for (int i = 0; i < 512; i++) ret_pc_cyc[i] = -1;
        early_post_cyc = -1; early_ld_n = 0;
        repeat (4) @(posedge clk);
        #1;
        load_image();
        for (int r = 1; r < 32; r++) core0.regfile0.gp_registers[r] = 64'b0;
        @(posedge clk); #1;
        rst = 1'b0;
        for (int c = 0; c < limit && !halted; c++) @(posedge clk);
        if (!halted) begin
            fail_count++; $display("FAIL: %s: EBREAK never reached", what);
        end
        #1;
    endtask

    function automatic logic [63:0] x(input int r); return core0.regfile0.gp_registers[r]; endfunction
    function automatic logic [63:0] b(input logic v); return {63'b0, v}; endfunction

    // ---------------- C and D: an event while an early load is on the bus ----------------
    int  pc_ev_first;
    task automatic build_load_stream();
        prologue();
        emit(i_(32'h80, 0, 3'b000, 31, `OPC_OP_IMM));                   // addi x31, x0, 0x80
        emit(encode_csr(`CSR_MIE, 5'd31, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM));            // csrw mie, x31: MTIE
        emit(encode_csr(`CSR_MSTATUS, 5'd8, `FUNCT3_CSRRSI, 5'd0, `OPC_SYSTEM));        // csrsi mstatus, 8: MIE
        pc_ev_first = here();
        for (int i = 0; i < 8; i++) begin
            emit(ld_(8 * i, 1, 3'b011, 10 + i));                        // ld   x(10+i), 8i(x1)
            // six addi x3, x3, 1: they retire one a cycle while the next load, started early, is on the bus
            for (int k = 0; k < 6; k++) emit(i_(1, 3, 3'b000, 3, `OPC_OP_IMM));
        end
        emit(EBREAK);
        handler();
    endtask
    task automatic check_stream(input string what);
        for (int i = 0; i < 8; i++)
            check($sformatf("%s: load %0d read its word", what, i), x(10 + i), init_word((32'h1000 >> 3) + i));
        check($sformatf("%s: every addi retired once", what), x(3), 64'd48);
    endtask

    logic ev_armed = 1'b0, ev_irq = 1'b0, ev_halt = 1'b0;
    logic ev_hit = 1'b0;                                 // the event was taken with an early load on the bus
    logic dbg_seen = 1'b0, dbg_lsu_busy_at_entry = 1'b0, dbg_show_ok = 1'b1, dbg_shown = 1'b0;
    always @(posedge clk) if (!rst) begin
        // raise the event once, when an early load is on the bus, once the stream's first load has retired (the
        // prologue's own load goes early too, before the interrupt is enabled)
        if (ev_armed && t_ret(pc_ev_first) >= 0 && core0.lsu0.in_bus && core0.lsu0.early_q) begin
            if (ev_irq)  mtip <= 1'b1;
            if (ev_halt) halt_req <= 1'b1;
            ev_armed <= 1'b0;
        end
        if (core0.interrupt_taken) begin
            if (core0.lsu0.in_bus && core0.lsu0.early_q) ev_hit <= 1'b1;
            mtip <= 1'b0;
        end
        if (core0.debug_halt_req_entry) begin
            if (core0.lsu0.in_bus && core0.lsu0.early_q) ev_hit <= 1'b1;
        end
        if (core0.in_debug_mode && !dbg_seen) begin
            dbg_seen <= 1'b1;
            dbg_lsu_busy_at_entry <= core0.lsu_in_bus;
        end
        if (debug_mode && !dbg_shown) begin
            dbg_shown <= 1'b1;
            if (core0.lsu_in_bus || !core0.sb_empty) dbg_show_ok <= 1'b0;
        end
        if (core0.in_debug_mode && !debug_mode && !core0.lsu_in_bus && core0.sb_empty) dbg_show_ok <= 1'b0;
    end

    // ---------------- the runs ----------------
    initial begin
        int pc_div, pc_bar, pc_tgt, t;

        // ===== A =====
        DW = 2;
        prologue();
        pc_div = here(); emit(div_(5, 6, 7));
        emit(ld_(8, 1, 3'b011, 11));                                    // ld   x11, 8(x1)    another dword
        emit(st_(0, 2, 1, 3'b011));                                     // sd   x2, 0(x1)
        emit(ld_(0, 1, 3'b011, 10));                                    // ld   x10, 0(x1)    the store's dword
        emit(EBREAK);
        handler();
        run(4000, "A");
        check("A: the load of the stored dword sees the store", x(10), K1);
        check("A: the other load read memory", x(11), init_word((32'h1008) >> 3));
        if (EARLY_ON) begin
            check("A: the other load went early (on the bus before the DIV retired)",
                  b(first_acc(32'h1008, 1'b0) >= 0 && first_acc(32'h1008, 1'b0) < t_ret(pc_div)), 64'd1);
            check("A: the store was posted early (before the DIV retired)", b(early_post_cyc >= 0 && early_post_cyc < t_ret(pc_div)), 64'd1);
        end
        check("A: the same-dword load read only after the store's write",
              b(first_acc(32'h1000, 1'b1) >= 0 && first_acc(32'h1000, 1'b0) > first_acc(32'h1000, 1'b1)), 64'd1);

        // ===== B: barriers =====
        prologue();
        pc_div = here(); emit(div_(5, 6, 7));
        pc_bar = here(); emit(encode_csr(`CSR_MIE, 5'd0, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM));   // csrw mie, x0: serializes
        emit(ld_(16, 1, 3'b011, 12));
        emit(EBREAK);
        handler();
        run(4000, "B1");
        check("B1: behind a serializing CSR write, the load reaches the bus only after it retires",
              b(first_acc(32'h1010, 1'b0) > t_ret(pc_bar) && t_ret(pc_bar) > 0), 64'd1);
        check("B1: the load's value", x(12), init_word((32'h1010) >> 3));
        prologue();
        pc_div = here(); emit(div_(5, 6, 7));
        pc_bar = here(); emit(32'h0220_000F);                           // fence r,r
        emit(ld_(16, 1, 3'b011, 12));
        emit(EBREAK);
        handler();
        run(4000, "B2");
        check("B2: behind a FENCE r,r, the load reaches the bus only after it retires",
              b(first_acc(32'h1010, 1'b0) > t_ret(pc_bar) && t_ret(pc_bar) > 0), 64'd1);

        // ===== E: outside the RAM window only at the head =====
        prologue();
        emit(encode_u(20'd2, 5'd8, `OPC_LUI));                          // lui  x8, 2         x8 = 0x2000
        pc_div = here(); emit(div_(5, 6, 7));
        emit(ld_(0, 8, 3'b011, 13));                                    // ld   x13, 0(x8)    error
        t = here();
        emit(st_(8, 2, 8, 3'b011));                                     // sd   x2, 8(x8)     error
        emit(EBREAK);
        handler();
        run(4000, "E");
        check("E: the load outside the window: only after the DIV retired",
              b(first_acc(32'h2000, 1'b0) > t_ret(pc_div) && t_ret(pc_div) > 0), 64'd1);
        check("E: the store outside the window: only after the DIV retired", b(first_acc(32'h2008, 1'b1) > t_ret(pc_div)), 64'd1);
        check("E: the store's fault is precise (cause 7 at its pc)", x(26), 64'd7);
        check("E: ... mepc", x(27), 64'(t));

        // ===== F: the wrong path =====
        prologue();
        emit(encode_u(20'd2, 5'd8, `OPC_LUI));                          // lui  x8, 2         x8 = 0x2000
        emit(encode_u(20'd2, 5'd9, `OPC_LUI));
        emit(i_(-2048, 9, 3'b000, 9, `OPC_OP_IMM));                     // x9 = 0x1800
        emit(i_(32'h1800 >> 2, 0, 3'b000, 20, `OPC_OP_IMM));            // pmpaddr0 = 0x1800 >> 2 (NA4)
        emit(encode_csr(`CSR_PMPADDR0, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM));
        emit(i_(-1, 0, 3'b000, 20, `OPC_OP_IMM));                       // pmpaddr1 = all ones (NAPOT: everything)
        emit(encode_csr(`CSR_PMPADDR1, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM));
        emit(encode_u(20'h2, 5'd20, `OPC_LUI));                         // x20 = 0x2000
        emit(i_(-32'h70, 20, 3'b000, 20, `OPC_OP_IMM));                 // x20 = 0x1F90: entry 0 locked NA4 no perms, entry 1 NAPOT RWX
        emit(encode_csr(`CSR_PMPCFG0, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM));
        pc_div = here(); emit(div_(5, 6, 7));
        t = here();
        emit(encode_b(8 * 4, 5'd0, 5'd0, 3'b000, `OPC_BRANCH));         // beq x0, x0, +32 (taken; predicted not taken)
        emit(ld_(32'h18, 1, 3'b011, 16));                               // wrong path: a RAM load
        emit(ld_(0, 9, 3'b011, 15));                                    // wrong path: denied by the PMP
        emit(ld_(0, 8, 3'b011, 14));                                    // wrong path: outside the window
        for (int i = 0; i < 4; i++) emit(NOP);
        pc_tgt = here();
        if (pc_tgt != t + 32) begin fail_count++; $display("FAIL: F: branch target mis-assembled"); end
        emit(EBREAK);
        handler();
        run(4000, "F");
        if (EARLY_ON) check("F: the wrong path ran (its RAM load went to the bus early)", b(first_acc(32'h1018, 1'b0) >= 0), 64'd1);
        check("F: the wrong-path load the PMP denies never reached the bus", b(any_acc(32'h1800)), 64'd0);
        check("F: the wrong-path load outside the window never reached the bus", b(any_acc(32'h2000)), 64'd0);
        check("F: no fault was taken", x(26), 64'd0);

        // ===== G: atomics =====
        prologue();
        emit(i_(32'h20, 1, 3'b000, 17, `OPC_OP_IMM));                   // x17 = 0x1020
        emit(i_(32'h30, 1, 3'b000, 20, `OPC_OP_IMM));                   // x20 = 0x1030
        pc_div = here(); emit(div_(5, 6, 7));
        emit(encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd4, 5'd17, `FUNCT3_AMO_D, 5'd18, `OPC_AMO));  // amoadd.d x18, x4, (x17)
        emit(ld_(32'h28, 1, 3'b011, 19));
        emit(encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0, 5'd20, `FUNCT3_AMO_D, 5'd21, `OPC_AMO));      // lr.d x21, (x20)
        emit(encode_amo(`FUNCT5_SC, 1'b0, 1'b0, 5'd4, 5'd20, `FUNCT3_AMO_D, 5'd22, `OPC_AMO));      // sc.d x22, x4, (x20)
        emit(ld_(32'h38, 1, 3'b011, 23));
        emit(EBREAK);
        handler();
        run(4000, "G");
        check("G: the AMO read, then wrote", b(first_acc(32'h1020, 1'b0) >= 0 && first_acc(32'h1020, 1'b1) > first_acc(32'h1020, 1'b0)), 64'd1);
        check("G: the load behind the AMO read only after the AMO's write",
              b(first_acc(32'h1028, 1'b0) > first_acc(32'h1020, 1'b1)), 64'd1);
        check("G: the SC succeeded", x(22), 64'd0);
        check("G: the load behind the SC read only after its write", b(first_acc(32'h1038, 1'b0) > first_acc(32'h1030, 1'b1)), 64'd1);
        check("G: the AMO's old value", x(18), init_word((32'h1020) >> 3));

        // ===== C: an interrupt while an early load is on the bus =====
        DW = 6;
        if (EARLY_ON) begin
        build_load_stream();
        ev_irq = 1'b1; ev_halt = 1'b0; ev_hit = 1'b0; ev_armed = 1'b1;
        run(8000, "C");
        ev_armed = 1'b0; ev_irq = 1'b0; mtip = 1'b0;
        check("C: the interrupt was taken with an early load on the bus", b(ev_hit), 64'd1);
        check("C: one interrupt handled", x(30), 64'd1);
        check_stream("C");

        // ===== D: a halt while an early load is on the bus =====
        build_load_stream();
        ev_irq = 1'b0; ev_halt = 1'b1; ev_hit = 1'b0;
        dbg_seen = 1'b0; dbg_shown = 1'b0; dbg_show_ok = 1'b1; dbg_lsu_busy_at_entry = 1'b0;
        fork
            run(8000, "D");
            begin
                @(negedge rst); ev_armed = 1'b1;
                wait (debug_mode);
                repeat (5) @(posedge clk);
                @(negedge clk); halt_req = 1'b0; resume_req = 1'b1;
                @(negedge clk); resume_req = 1'b0;
            end
        join
        ev_armed = 1'b0; ev_halt = 1'b0;
        check("D: the halt was taken with an early load on the bus", b(ev_hit), 64'd1);
        check("D: the hart was halted while the port was still busy", b(dbg_lsu_busy_at_entry), 64'd1);
        check("D: it showed as halted only once the port was quiet (and never stayed hidden once it was)", b(dbg_show_ok), 64'd1);
        check("D: it showed as halted", b(dbg_shown), 64'd1);
        check_stream("D");
        end

        $display("");
        $display("core_lsq_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_lsq_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
