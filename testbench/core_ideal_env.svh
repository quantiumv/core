// SPDX-License-Identifier: MIT

/*
 * core_ideal_env.svh -- the end-to-end harness shared by core_lsq_tb and core_dc_tb: the core with an ideal fetch
 * port, one memory behind its data port with a fixed number of wait states and a log of every access, the program
 * builders (emit, the instruction helpers, prologue, handler), the retirement-cycle table and run().
 *
 * `include'd inside the testbench module, at its top (it declares clk, rst and the check counters and includes
 * check_lib.sv itself).
 */
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
    // the cycle of the last access (read or write) to a dword, -1 if none
    function automatic int last_acc(input logic [31:0] a, input logic we);
        int r = -1;
        for (int i = 0; i < log_cyc.size(); i++)
            if (log_addr[i] == {a[31:3], 3'b000} && log_we[i] == we) r = log_cyc[i];
        return r;
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
