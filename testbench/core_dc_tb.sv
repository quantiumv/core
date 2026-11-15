// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, the D$ inside the core (O5a, QV_PIPE_DCACHE), end to end. The harness is core_lsq_tb's: fetch from
 * an ideal port, the memory port on a slave with DW wait states, every access logged, one memory of 8 KiB that is all
 * RAM (the D$ is 64 lines of 32 bytes, so 0x1000 and 0x1800 share an index). Code at 0, a handler at 0x600, data at
 * 0x1000 (x1).
 *   A  load-to-use: once its line is in, a load completes in the LSU's first cycle with no bus access, and a value
 *      loaded is used by the next instruction
 *   P  a pointer chase over 16 nodes in held lines: no bus access at all, the right last node
 *   S  stores drain while loads of the same line hit: the loads see memory's dwords, the stores reach memory in order,
 *      and a load of a just-stored dword sees the store
 *   X  two lines that share an index, loaded in turn: each load refills, each value right
 *   I  an interrupt raised while a refill is on the bus (without the D$: while a load is): the values are right after
 *      the handler
 *   H  a halt raised the same way: the hart shows as halted only once the refill is over
 * Checked every cycle: o_debug_mode never while a refill is in progress, and the LSU never drives the port during one.
 */
module core_dc_tb;
    // the build has the D$ inside the core (QV_PIPE_DCACHE; core.sv defines the knob). Without it the runs check
    // only what holds either way: the values, and the bus order of the stores.
    localparam bit DC_ON = (`QV_PIPE_DCACHE != 0);

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

    // ---------------- checked every cycle ----------------
    logic inv_ok = 1'b1;
    int   dc_done_n = 0, dc_miss_n = 0;
    always @(posedge clk) if (!rst) begin
        if (debug_mode && core0.dc_busy) inv_ok = 1'b0;
        if (core0.dc_busy && core0.lsu0.wb_mem_cyc_o) inv_ok = 1'b0;
        if (core0.lsu0.done_dc) dc_done_n = dc_done_n + 1;
        if (core0.lsu0.dc_miss) dc_miss_n = dc_miss_n + 1;
    end
    // a hit that completes in the cycle right after the LSU took it (the done check first: a handoff takes the next
    // op in that same cycle)
    int   acc_cyc_t [0:(1 << qv_pkg::QV_ROB_TAG_W) - 1];       // by tag
    logic lat1_seen = 1'b0;
    always @(posedge clk) if (!rst) begin
        if (core0.lsu0.done_dc && acc_cyc_t[core0.lsu0.tag_q] == cyc_n - 1) lat1_seen = 1'b1;
        if (core0.lsu0.accept) acc_cyc_t[core0.lsu0.i_req.tag] = cyc_n;
    end

    logic ev_armed = 1'b0, ev_irq = 1'b0, ev_halt = 1'b0, ev_hit = 1'b0;
    int   halt_show_cyc = -1;
    always @(posedge clk) if (!rst) begin
        if (ev_armed && (DC_ON ? core0.dc_busy : core0.lsu0.in_bus)) begin
            if (ev_irq)  mtip <= 1'b1;
            if (ev_halt) halt_req <= 1'b1;
            ev_armed <= 1'b0;
            ev_hit <= 1'b1;
        end
        if (core0.interrupt_taken) mtip <= 1'b0;
        if (debug_mode && halt_show_cyc < 0) halt_show_cyc = cyc_n;
    end
    function automatic int nreads(input logic [31:0] lo, input logic [31:0] hi);
        int c = 0;
        for (int i = 0; i < log_cyc.size(); i++) if (!log_we[i] && log_addr[i] >= lo && log_addr[i] < hi) c++;
        return c;
    endfunction

    // ---------------- the runs ----------------
    initial begin
        DW = 1;

        // ===== A: load-to-use =====
        prologue();
        emit(ld_(0, 1, 3'b011, 10));                                    // ld   x10, 0(x1)   refills 0x1000
        for (int k = 0; k < 8; k++) emit(NOP);
        emit(ld_(8, 1, 3'b011, 11));                                    // ld   x11, 8(x1)   a hit
        emit(i_(1, 11, 3'b000, 12, `OPC_OP_IMM));                       // addi x12, x11, 1  uses it at once
        emit(EBREAK);
        handler();
        run(4000, "A");
        check("A: the first load's dword", x(10), init_word(32'h1000 >> 3));
        check("A: the second load's dword", x(11), init_word(32'h1008 >> 3));
        check("A: its value used by the next instruction", x(12), init_word(32'h1008 >> 3) + 64'd1);
        if (DC_ON) begin
            check("A: one refill of the line (4 reads), none for the hit", 64'(nreads(32'h1000, 32'h1020)), 64'd4);
            check("A: a hit completes in the cycle after the LSU took it", b(lat1_seen), 64'd1);
        end

        // ===== P: a pointer chase over held lines =====
        prologue();
        // nodes at 0x1100 + 16*i, each holding the next node's address; the loop warms them first, then chases
        emit(i_(32'h100, 1, 3'b000, 5, `OPC_OP_IMM));                   // addi x5, x1, 0x100
        emit(i_(16, 0, 3'b000, 6, `OPC_OP_IMM));                        // addi x6, x0, 16
        emit(ld_(0, 5, 3'b011, 5));                                     // loop: ld x5, 0(x5)
        emit(i_(-1, 6, 3'b000, 6, `OPC_OP_IMM));                        //       addi x6, x6, -1
        emit(encode_b(-8, 5'd0, 5'd6, 3'b001, `OPC_BRANCH));            //       bne x6, x0, loop
        emit(i_(32'h100, 1, 3'b000, 5, `OPC_OP_IMM));                   // again, the lines held now
        emit(i_(16, 0, 3'b000, 6, `OPC_OP_IMM));
        emit(ld_(0, 5, 3'b011, 5));
        emit(i_(-1, 6, 3'b000, 6, `OPC_OP_IMM));
        emit(encode_b(-8, 5'd0, 5'd6, 3'b001, `OPC_BRANCH));
        emit(EBREAK);
        handler();
        rst = 1'b1;
        run_nodes();
        check("P: the chase ends at the 16th node", x(5), 64'h1100 + 64'd16 * 64'd16);
        if (DC_ON)
            check("P: the nodes' 8 lines refilled once (32 reads): the second chase all hits",
                  64'(nreads(32'h1100, 32'h1200)), 64'd32);

        // ===== S: stores drain while loads of the same line hit =====
        prologue();
        emit(ld_(32'h40, 1, 3'b011, 10));                               // ld   x10, 0x40(x1): the line in
        emit(st_(32'h48, 2, 1, 3'b011));                                // sd   x2, 0x48(x1)
        emit(ld_(32'h50, 1, 3'b011, 11));                               // ld   x11, 0x50(x1): a hit beside the drain
        emit(st_(32'h58, 4, 1, 3'b011));                                // sd   x4, 0x58(x1)
        emit(ld_(32'h40, 1, 3'b011, 12));                               // ld   x12, 0x40(x1)
        emit(ld_(32'h48, 1, 3'b011, 13));                               // ld   x13, 0x48(x1): the stored dword
        emit(ld_(32'h58, 1, 3'b011, 14));                               // ld   x14, 0x58(x1)
        emit(EBREAK);
        handler();
        run(4000, "S");
        check("S: hit beside the drain", x(11), init_word(32'h1050 >> 3));
        check("S: hit of an untouched dword", x(12), init_word(32'h1040 >> 3));
        check("S: the first store's dword", x(13), K1);
        check("S: the second store's dword", x(14), 64'd1);
        check("S: memory got both stores", mem[32'h1048 >> 3], K1);
        check("S: ... the second", mem[32'h1058 >> 3], 64'd1);
        check("S: the stores reached memory in order",
              b(first_acc(32'h1048, 1'b1) >= 0 && first_acc(32'h1058, 1'b1) > first_acc(32'h1048, 1'b1)), 64'd1);
        if (DC_ON) check("S: one refill for the line, nothing else read", 64'(nreads(32'h1040, 32'h1060)), 64'd4);

        // ===== X: two lines on one index, in turn =====
        prologue();
        emit(i_(32'h400, 1, 3'b000, 9, `OPC_OP_IMM));                   // addi x9, x1, 0x400
        emit(i_(32'h400, 9, 3'b000, 9, `OPC_OP_IMM));                   // addi x9, x9, 0x400: 0x1800, index 0 too
        for (int k = 0; k < 6; k++) begin
            emit(ld_(32'h18, 1, 3'b011, 10 + k));                       // ld   0x1018
            emit(ld_(32'h18, 9, 3'b011, 16 + k));                       // ld   0x1818
        end
        emit(EBREAK);
        handler();
        run(8000, "X");
        for (int k = 0; k < 6; k++) begin
            check($sformatf("X: 0x1018 load %0d", k), x(10 + k), init_word(32'h1018 >> 3));
            check($sformatf("X: 0x1818 load %0d", k), x(16 + k), init_word(32'h1818 >> 3));
        end
        if (DC_ON) check("X: every load refilled its line (12 refills)",
                         64'(nreads(32'h1000, 32'h1020) + nreads(32'h1800, 32'h1820)), 64'd48);

        // ===== I: an interrupt raised while a refill is on the bus =====
        prologue();
        emit(i_(32'h80, 0, 3'b000, 31, `OPC_OP_IMM));
        emit(encode_csr(`CSR_MIE, 5'd31, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM));
        emit(encode_csr(`CSR_MSTATUS, 5'd8, `FUNCT3_CSRRSI, 5'd0, `OPC_SYSTEM));
        for (int k = 0; k < 8; k++) begin
            emit(ld_(32'h200 + 32 * k, 1, 3'b011, 10 + k));             // a new line each
            emit(i_(1, 3, 3'b000, 3, `OPC_OP_IMM));
        end
        emit(EBREAK);
        handler();
        ev_irq = 1'b1; ev_halt = 1'b0; ev_hit = 1'b0;
        fork
            run(8000, "I");
            begin wait (!rst); repeat (40) @(posedge clk); ev_armed = 1'b1; end
        join
        ev_armed = 1'b0; ev_irq = 1'b0;
        for (int k = 0; k < 8; k++)
            check($sformatf("I: load %0d", k), x(10 + k), init_word((32'h1200 + 32 * k) >> 3));
        check("I: every addi once", x(3), 64'd8);
        check("I: the interrupt was taken", b(x(30) >= 1), 64'd1);
        if (DC_ON) check("I: it was raised during a refill", b(ev_hit), 64'd1);

        // ===== H: a halt raised while a refill is on the bus =====
        ev_halt = 1'b1; ev_hit = 1'b0; halt_show_cyc = -1;
        fork
            run(8000, "H");
            begin
                wait (!rst); repeat (40) @(posedge clk); ev_armed = 1'b1;
                wait (debug_mode); repeat (20) @(posedge clk);
                halt_req = 1'b0; resume_req = 1'b1; @(posedge clk); resume_req = 1'b0;
            end
        join
        ev_armed = 1'b0; ev_halt = 1'b0;
        for (int k = 0; k < 8; k++)
            check($sformatf("H: load %0d", k), x(10 + k), init_word((32'h1200 + 32 * k) >> 3));
        check("H: the hart halted", b(halt_show_cyc >= 0), 64'd1);
        if (DC_ON) check("H: it was raised during a refill", b(ev_hit), 64'd1);

        check("never shown as halted during a refill, never the LSU on the port during one", b(inv_ok), 64'd1);
        $display("");
        $display("core_dc_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_dc_tb: FAILURES PRESENT");
        $finish;
    end

    // P's run: the image with the nodes
    task automatic run_nodes();
        rst = 1'b1; halted = 1'b0;
        log_cyc.delete(); log_addr.delete(); log_we.delete(); log_err.delete();
        for (int i = 0; i < 512; i++) ret_pc_cyc[i] = -1;
        repeat (4) @(posedge clk);
        #1;
        load_image();
        for (int i = 0; i < 16; i++) mem[(32'h1100 + 16 * i) >> 3] = 64'h1100 + 64'(16 * (i + 1));
        for (int r = 1; r < 32; r++) core0.regfile0.gp_registers[r] = 64'b0;
        @(posedge clk); #1;
        rst = 1'b0;
        for (int c = 0; c < 8000 && !halted; c++) @(posedge clk);
        if (!halted) begin fail_count++; $display("FAIL: P: EBREAK never reached"); end
        #1;
    endtask

    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
