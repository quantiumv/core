// SPDX-License-Identifier: MIT

/*
 * qv_align_fifo_tb -- standalone test for design/pipe/qv_align.sv and
 * design/pipe/qv_fifo.sv, wired the way core_pipe uses them (fetch
 * buffer -> align -> IQ).
 *
 * The source behaves like qv_fetch: it plays dwords out of a memory image
 * sequentially from a start pc (the first carrying the real pc, the rest
 * dword-aligned) and restarts at align's redirect target. Programs are
 * laid into the image with a side table recording which instructions
 * are statically predictable and their targets, written from the
 * encoders' own offsets -- never from the RTL's formulas. A golden
 * walker follows the same predicted control flow, and every instruction
 * leaving the IQ must match it in pc, bits, length, predicted-taken bit
 * and predicted target. Random programs mix 16/32-bit instructions,
 * dword crossings, JAL/C.J, backward and forward branches (32-bit and
 * C.BEQZ/C.BNEZ) and loops, under random consumer backpressure, with
 * flushes between and in the middle of programs. Directed checks cover
 * fetch faults, no movement without IQ room, and the FIFO's threshold,
 * wraparound and empty-pop behavior.
 */
`include "riscv_encode.sv"

module qv_align_fifo_tb;
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    localparam int W = $bits(fe_instr_t);

    // ---------------- align -> fifo ----------------
    logic        buf_valid, buf_err;
    logic [63:0] buf_pc, buf_data;
    logic        buf_pop;
    logic        p0_valid, p1_valid, push_ready;
    fe_instr_t   p0_data, p1_data;
    logic        fe_redir;
    logic [63:0] fe_redir_pc;
    logic        flush = 1'b0;
    logic        head_valid;
    logic [W-1:0] head_bits;
    fe_instr_t   head;
    logic        pop_en = 1'b0;
    int          pop_pct = 100;
    logic        force_pop = 1'b0;
    logic        pop;

    assign head = fe_instr_t'(head_bits);

    qv_align align0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_buf_valid(buf_valid), .i_buf_pc(buf_pc), .i_buf_data(buf_data), .i_buf_err(buf_err),
        .o_buf_pop(buf_pop),
        .o_push0_valid(p0_valid), .o_push0_data(p0_data),
        .o_push1_valid(p1_valid), .o_push1_data(p1_data),
        .i_push_ready(push_ready),
        .o_redirect_valid(fe_redir), .o_redirect_pc(fe_redir_pc)
    );

    qv_fifo #(.WIDTH(W), .DEPTH(4)) iq0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_push0_valid(p0_valid), .i_push0_data(p0_data),
        .i_push1_valid(p1_valid), .i_push1_data(p1_data),
        .o_push_ready(push_ready),
        .o_head_valid(head_valid), .o_head_data(head_bits),
        .i_pop(pop)
    );

    // ---------------- consumer ----------------
    logic pop_roll;
    always @(negedge clk) pop_roll = ($urandom % 100) < pop_pct;
    assign pop = (pop_en && head_valid && pop_roll) || force_pop;

    localparam int MAXI = 128;
    logic [63:0] log_pc   [0:MAXI-1];
    logic [31:0] log_raw  [0:MAXI-1];
    logic        log_rvc  [0:MAXI-1];
    logic        log_xcpt [0:MAXI-1];
    logic [3:0]  log_cause[0:MAXI-1];
    logic        log_hi   [0:MAXI-1];
    logic        log_pred [0:MAXI-1];
    logic [63:0] log_tgt  [0:MAXI-1];
    int log_n = 0;
    always @(posedge clk) begin
        if (!rst && !flush && pop && head_valid && log_n < MAXI) begin
            log_pc[log_n]    <= head.pc;
            log_raw[log_n]   <= head.raw;
            log_rvc[log_n]   <= head.rvc;
            log_xcpt[log_n]  <= head.xcpt;
            log_cause[log_n] <= head.xcpt_cause;
            log_hi[log_n]    <= head.xcpt_hi;
            log_pred[log_n]  <= head.pred_taken;
            log_tgt[log_n]   <= head.pred_tgt;
            log_n            <= log_n + 1;
        end
    end

    // ---------------- memory image + fetch-like source ----------------
    localparam int MEM_HW = 2048;                   // 4 KiB
    logic [15:0] mem   [0:MEM_HW-1];
    logic        err_d [0:MEM_HW/4-1];              // per dword
    logic        pred_at [0:MEM_HW-1];              // side table, per instruction start
    logic [63:0] tgt_at  [0:MEM_HW-1];

    logic [63:0] fpc;                               // pc of the dword being presented
    logic [63:0] flimit = '0;                       // stop presenting at/after this address
    logic        src_en = 1'b0;
    logic [63:0] restart_pc;

    always @(posedge clk) begin
        if (rst || flush)              fpc <= restart_pc;
        else if (src_en && fe_redir)   fpc <= fe_redir_pc;
        else if (src_en && buf_pop)    fpc <= {fpc[63:3], 3'b000} + 64'd8;
    end
    always_comb begin
        buf_valid = src_en && (fpc < flimit);
        buf_pc    = fpc;
        buf_data  = {mem[{fpc[11:3], 2'd3}], mem[{fpc[11:3], 2'd2}], mem[{fpc[11:3], 2'd1}], mem[{fpc[11:3], 2'd0}]};
        buf_err   = buf_valid && err_d[fpc[11:3]];
    end

    // ---------------- program layout ----------------
    function automatic logic [15:0] rand_c();       // a compressed hw that isn't predictable
        logic [15:0] h;
        do begin
            h = 16'($urandom);
            if (h[1:0] == 2'b11) h[1:0] = 2'($urandom % 3);
        end while (h[1:0] == 2'b01 && (h[15:13] == 3'b101 || (h[15:14] == 2'b11 && h[12])));
        return h;
    endfunction

    function automatic logic [31:0] rand_32();      // a 32-bit encoding that isn't JAL/branch
        logic [31:0] w;
        do w = {$urandom} | 32'h3; while (w[6:0] == 7'b1101111 || w[6:0] == 7'b1100011);
        return w;
    endfunction

    task automatic clear_mem();
        for (int i = 0; i < MEM_HW; i++) begin
            mem[i] = rand_c();
            pred_at[i] = 1'b0;
            tgt_at[i] = '0;
        end
        for (int i = 0; i < MEM_HW / 4; i++) err_d[i] = 1'b0;
    endtask

    task automatic put16(input logic [63:0] a, input logic [15:0] h, input logic pred = 1'b0,
                         input logic [63:0] tgt = '0);
        mem[a[11:1]] = h;
        pred_at[a[11:1]] = pred;
        tgt_at[a[11:1]] = tgt;
    endtask

    task automatic put32(input logic [63:0] a, input logic [31:0] w, input logic pred = 1'b0,
                         input logic [63:0] tgt = '0);
        mem[a[11:1]]      = w[15:0];
        mem[a[11:1] + 1]  = w[31:16];
        pred_at[a[11:1]]  = pred;
        tgt_at[a[11:1]]   = tgt;
    endtask

    // golden walk along the predicted path
    logic [63:0] exp_pc  [0:MAXI-1];
    logic [31:0] exp_raw [0:MAXI-1];
    logic        exp_rvc [0:MAXI-1];
    logic        exp_pred[0:MAXI-1];
    logic [63:0] exp_tgt [0:MAXI-1];
    int exp_n;

    task automatic walk(input logic [63:0] start, input int n);
        logic [63:0] pc;
        pc = start;
        for (int k = 0; k < n; k++) begin
            exp_pc[k]   = pc;
            exp_pred[k] = pred_at[pc[11:1]];
            exp_tgt[k]  = tgt_at[pc[11:1]];
            if (mem[pc[11:1]][1:0] != 2'b11) begin
                exp_raw[k] = {16'b0, mem[pc[11:1]]};
                exp_rvc[k] = 1'b1;
            end else begin
                exp_raw[k] = {mem[pc[11:1] + 1], mem[pc[11:1]]};
                exp_rvc[k] = 1'b0;
            end
            pc = exp_pred[k] ? exp_tgt[k] : pc + (exp_rvc[k] ? 64'd2 : 64'd4);
        end
        exp_n = n;
    endtask

    // A random program of n instructions from start: unpredictable ALU-
    // shaped filler, plus (pctl%) control flow: JAL/C.J anywhere, backward
    // branches (taken) and forward ones (not), all targeting the start of
    // another instruction of the program.
    logic [63:0] ipc [0:MAXI-1];
    task automatic make_prog(input logic [63:0] start, input int n, input int rvc_pct, input int pctl);
        logic [63:0] a;
        logic [3:0]  kind [0:MAXI-1];
        int t;
        a = start;
        for (int k = 0; k < n; k++) begin          // pass 1: lengths and kinds
            ipc[k] = a;
            kind[k] = (($urandom % 100) < pctl) ? 4'(1 + $urandom % 6) : 4'd0;
            if (kind[k] == 0) a += (($urandom % 100) < rvc_pct) ? 64'd2 : 64'd4;
            else              a += (kind[k] <= 3) ? 64'd4 : 64'd2;
            if (kind[k] == 0) begin
                if (a - ipc[k] == 2) put16(ipc[k], rand_c());
                else                 put32(ipc[k], rand_32());
            end
        end
        for (int k = 0; k < n; k++) begin          // pass 2: control flow, now every start is known
            int off_b, off_f;
            t = $urandom % n;                       // any instruction
            off_b = int'(ipc[k < 1 ? 0 : $urandom % (k + 1)]) - int'(ipc[k]);  // at or before k
            off_f = int'(ipc[(k + 1 + $urandom % (n - k)) % n]) - int'(ipc[k]);
            case (kind[k])
                4'd1: put32(ipc[k], encode_j(int'(ipc[t]) - int'(ipc[k]), 5'($urandom), `OPC_JAL), 1'b1, ipc[t]);
                4'd2: if (off_b < 0)
                          put32(ipc[k], encode_b(off_b, 5'($urandom), 5'($urandom), 3'b001, `OPC_BRANCH), 1'b1,
                                ipc[k] + 64'(off_b));
                      else
                          put32(ipc[k], rand_32());
                4'd3: if (off_f > 0)
                          put32(ipc[k], encode_b(off_f, 5'($urandom), 5'($urandom), 3'b100, `OPC_BRANCH));
                      else
                          put32(ipc[k], rand_32());
                4'd4: if (int'(ipc[t]) - int'(ipc[k]) >= -2048 && int'(ipc[t]) - int'(ipc[k]) < 2048)
                          put16(ipc[k], encode_c_j(int'(ipc[t]) - int'(ipc[k])), 1'b1, ipc[t]);
                      else
                          put16(ipc[k], rand_c());
                4'd5: if (off_b < 0 && off_b >= -256)
                          put16(ipc[k], encode_c_beqz(off_b, 3'($urandom)), 1'b1, ipc[k] + 64'(off_b));
                      else
                          put16(ipc[k], rand_c());
                4'd6: if (off_f > 0 && off_f < 256)
                          put16(ipc[k], encode_c_bnez(off_f, 3'($urandom)));
                      else
                          put16(ipc[k], rand_c());
                default: ;
            endcase
        end
        flimit = 64'(2 * MEM_HW);
    endtask

    task automatic flush_all(input logic [63:0] next_start);
        @(negedge clk);
        src_en     = 1'b0;
        pop_en     = 1'b0;
        restart_pc = next_start;
        flush      = 1'b1;
        @(negedge clk);
        flush      = 1'b0;
        log_n      = 0;
    endtask

    task automatic run_check(input string name, input int upto, input int max_cycles);
        int c;
        src_en = 1'b1;
        pop_en = 1'b1;
        for (c = 0; c < max_cycles && log_n < upto; c++) @(posedge clk);
        #1;
        check({name, ": instruction count"}, 64'(log_n >= upto), 64'd1);
        for (int k = 0; k < upto && k < log_n; k++) begin
            check($sformatf("%s: #%0d pc", name, k), log_pc[k], exp_pc[k]);
            check($sformatf("%s: #%0d raw", name, k), {32'b0, log_raw[k]}, {32'b0, exp_raw[k]});
            check($sformatf("%s: #%0d rvc", name, k), {63'b0, log_rvc[k]}, {63'b0, exp_rvc[k]});
            check($sformatf("%s: #%0d predicted", name, k), {63'b0, log_pred[k]}, {63'b0, exp_pred[k]});
            if (exp_pred[k]) check($sformatf("%s: #%0d target", name, k), log_tgt[k], exp_tgt[k]);
            check($sformatf("%s: #%0d no fault", name, k), {63'b0, log_xcpt[k]}, 64'd0);
        end
    endtask

    function automatic logic [31:0] w32(input int x);   // a 32-bit non-control encoding
        return {x[29:0], 2'b11} & ~32'h0000_0040;        // opcode bit 6 clear: never JAL/branch
    endfunction

    int k, s, cut;
    logic [63:0] st;

    initial begin
        restart_pc = '0;
        clear_mem();
        repeat (2) @(posedge clk);
        #1 rst = 1'b0;

        // ---- D1: four RVC in one dword ----
        flush_all(64'h100);
        make_prog(64'h100, 4, 100, 0);
        walk(64'h100, 4);
        run_check("D1 four rvc", 4, 40);

        // ---- D2: 32-bit instructions crossing dwords, from the first one on ----
        flush_all(64'h206);
        make_prog(64'h206, 6, 0, 0);
        walk(64'h206, 6);
        run_check("D2 crossing", 6, 60);

        // ---- D3: starts at every halfword ----
        for (s = 0; s < 4; s++) begin
            flush_all(64'h300 + 64'(2 * s));
            make_prog(64'h300 + 64'(2 * s), 8, 50, 0);
            walk(64'h300 + 64'(2 * s), 8);
            run_check($sformatf("D3 start hw %0d", s), 8, 80);
        end

        // ---- P: prediction, directed ----
        clear_mem();
        // JAL in slot 0 with a valid instruction after it in the same dword: that one is dropped
        put32(64'h400, encode_j(64, 1, `OPC_JAL), 1'b1, 64'h440);
        put32(64'h404, w32(1));
        put32(64'h440, w32(2)); put32(64'h444, w32(3));
        flush_all(64'h400);
        flimit = 64'h1000;
        walk(64'h400, 3);
        run_check("P1 JAL in slot 0", 3, 40);
        // JAL in slot 1, target mid-dword (pc[2:1] = 3)
        clear_mem();
        put16(64'h500, rand_c());
        put32(64'h502, encode_j(-246, 0, `OPC_JAL), 1'b1, 64'h40C);
        put16(64'h40E, rand_c());
        flush_all(64'h500);
        walk(64'h500, 5);
        run_check("P2 JAL in slot 1, odd-halfword target", 5, 40);
        // crossing JAL (assembled from a held half), backward
        clear_mem();
        put16(64'h600, rand_c()); put16(64'h602, rand_c()); put16(64'h604, rand_c());
        put32(64'h606, encode_j(-262, 0, `OPC_JAL), 1'b1, 64'h500);
        flush_all(64'h600);
        walk(64'h600, 8);
        run_check("P3 crossing JAL", 8, 60);
        // 32-bit branches: backward predicted, forward not, invalid funct3 never
        clear_mem();
        put32(64'h700, encode_b(16, 3, 4, 3'b000, `OPC_BRANCH));                      // forward: not
        put32(64'h704, {encode_b(-4, 3, 4, 3'b000, `OPC_BRANCH)} | 32'h0000_2000);    // funct3 010: never
        put32(64'h708, encode_b(-8, 3, 4, 3'b111, `OPC_BRANCH), 1'b1, 64'h700);       // backward: taken
        flush_all(64'h700);
        walk(64'h700, 9);
        run_check("P4 32-bit branches", 9, 80);
        // RVC: C.J both ways, C.BEQZ backward, C.BNEZ forward
        clear_mem();
        put16(64'h800, encode_c_bnez(6, 3'd1));                                       // forward: not
        put16(64'h802, encode_c_j(14), 1'b1, 64'h810);
        put16(64'h810, rand_c());
        put16(64'h812, encode_c_beqz(-16, 3'd2), 1'b1, 64'h802);
        flush_all(64'h800);
        walk(64'h800, 10);
        run_check("P5 RVC control flow", 10, 80);
        clear_mem();
        put16(64'h900, encode_c_j(-2048), 1'b1, 64'h100);
        flush_all(64'h900);
        walk(64'h900, 3);
        run_check("P6 C.J max backward", 3, 40);

        // ---- D4: no movement without IQ room ----
        clear_mem();
        flush_all(64'hA00);
        make_prog(64'hA00, 12, 50, 20);
        walk(64'hA00, 12);
        src_en = 1'b1;
        force push_ready = 1'b0;
        #1;
        check("D4: no pop without room", {63'b0, buf_pop}, 64'd0);
        check("D4: no push without room", {63'b0, p0_valid | p1_valid}, 64'd0);
        check("D4: no redirect without room", {63'b0, fe_redir}, 64'd0);
        repeat (3) @(posedge clk);
        release push_ready;
        run_check("D4: program intact after the stall", 12, 120);

        // ---- D5: flush while a crossing half is held ----
        clear_mem();
        put32(64'hB06, w32(5));                         // its high half at 0xB08 never arrives
        flush_all(64'hB00);
        flimit = 64'hB08;
        src_en = 1'b1; pop_en = 1'b1;
        repeat (10) @(posedge clk);
        #1;
        check("D5: the three rvc before it came out", 64'(log_n), 64'd3);
        flush_all(64'hC00);
        make_prog(64'hC00, 8, 50, 0);
        walk(64'hC00, 8);
        run_check("D5: no stale half after flush", 8, 80);

        // ---- D6: fetch faults ----
        clear_mem();
        flush_all(64'hD00);
        make_prog(64'hD00, 10, 50, 0);
        err_d[64'hD08 >> 3] = 1'b1;
        walk(64'hD00, 10);
        cut = 0;
        while (cut < exp_n && exp_pc[cut] + (exp_rvc[cut] ? 64'd2 : 64'd4) <= 64'hD08) cut++;
        src_en = 1'b1; pop_en = 1'b1;
        repeat (30) @(posedge clk);
        #1;
        check("D6: instructions up to the fault", 64'(log_n >= cut + 1), 64'd1);
        for (k = 0; k < cut; k++) begin
            check($sformatf("D6: #%0d before fault pc", k), log_pc[k], exp_pc[k]);
            check($sformatf("D6: #%0d before fault clean", k), {63'b0, log_xcpt[k]}, 64'd0);
        end
        check("D6: marker pc", log_pc[cut], exp_pc[cut]);
        check("D6: marker faulted", {63'b0, log_xcpt[cut]}, 64'd1);
        check("D6: marker cause 1", {60'b0, log_cause[cut]}, 64'd1);
        check("D6: marker xcpt_hi iff it crossed in", {63'b0, log_hi[cut]}, {63'b0, exp_pc[cut] < 64'hD08});
        check("D6: marker never predicted", {63'b0, log_pred[cut]}, 64'd0);
        clear_mem();
        put32(64'hE06, w32(6));                         // crosses into a faulting dword
        err_d[64'hE08 >> 3] = 1'b1;
        flush_all(64'hE00);
        src_en = 1'b1; pop_en = 1'b1;
        repeat (10) @(posedge clk);
        #1;
        check("D6b: three rvc then the marker", 64'(log_n >= 4), 64'd1);
        check("D6b: marker at the crossing pc", log_pc[3], 64'hE06);
        check("D6b: marker faulted", {63'b0, log_xcpt[3]}, 64'd1);
        check("D6b: marker xcpt_hi", {63'b0, log_hi[3]}, 64'd1);

        // ---- R1: random programs with control flow, random backpressure ----
        for (s = 0; s < 300; s++) begin
            clear_mem();
            st = 64'h100 + 64'(($urandom % 64) * 2);
            flush_all(st);
            pop_pct = 20 + $urandom % 81;
            make_prog(st, 2 + $urandom % 40, (s % 3 == 0) ? 0 : (s % 3 == 1) ? 50 : 90, (s % 4) * 10);
            walk(st, 60);
            run_check($sformatf("R1 program %0d", s), 60, 600);
        end

        // ---- R3: every offset bit of every predicted form ----
        // One predictable instruction after 0-3 fillers, with an offset
        // drawn from its form's whole range; only the instructions up to
        // and including it are checked (its target may lie outside the
        // image).
        for (s = 0; s < 3000; s++) begin
            int form, nf, off;
            logic [63:0] a;
            clear_mem();
            st = 64'h400 + 64'(($urandom % 256) * 2);
            flush_all(st);
            nf = $urandom % 4;
            a = st;
            for (k = 0; k < nf; k++) begin
                if ($urandom % 2) begin put16(a, rand_c()); a += 2; end
                else              begin put32(a, rand_32()); a += 4; end
            end
            form = $urandom % 5;
            case (form)
                0: begin off = int'($urandom % (1 << 20)) * 2 - (1 << 20);       // JAL, +-1 MiB
                         put32(a, encode_j(off, 5'($urandom), `OPC_JAL), 1'b1, a + 64'(off)); end
                1: begin off = -2 - 2 * int'($urandom % 2048);                   // backward branch
                         put32(a, encode_b(off, 5'($urandom), 5'($urandom), 3'b101, `OPC_BRANCH), 1'b1,
                               a + 64'(off)); end
                2: begin off = int'($urandom % 2048) * 2 - 2048;                 // C.J, +-2 KiB
                         put16(a, encode_c_j(off), 1'b1, a + 64'(off)); end
                3: begin off = -2 - 2 * int'($urandom % 128);                    // C.BEQZ backward
                         put16(a, encode_c_beqz(off, 3'($urandom)), 1'b1, a + 64'(off)); end
                default: begin off = -2 - 2 * int'($urandom % 128);              // C.BNEZ backward
                         put16(a, encode_c_bnez(off, 3'($urandom)), 1'b1, a + 64'(off)); end
            endcase
            flimit = 64'(2 * MEM_HW);
            walk(st, nf + 1);
            run_check($sformatf("R3 form %0d offset %0d", form, off), nf + 1, 60);
        end

        // ---- R2: flush mid-program, then an exact clean one ----
        for (s = 0; s < 200; s++) begin
            clear_mem();
            pop_pct = 30 + $urandom % 71;
            flush_all(64'h100 + 64'(($urandom % 64) * 2));
            make_prog(restart_pc, 20, 50, 20);
            src_en = 1'b1; pop_en = 1'b1;
            repeat ($urandom % 12) @(posedge clk);
            st = 64'h800 + 64'(($urandom % 64) * 2);
            flush_all(st);
            make_prog(st, 2 + $urandom % 20, 50, 20);
            walk(st, 40);
            run_check($sformatf("R2 after flush %0d", s), 40, 400);
        end
        pop_pct = 100;

        // ---- F1: fifo ready threshold and wraparound ordering ----
        clear_mem();
        for (k = 0; k < 8; k++) put32(64'(4 * k), w32(16 * (k / 2 + 1) + (k % 2)));
        flush_all(64'h0);
        flimit = 64'h20;
        src_en = 1'b1;
        @(posedge clk); #1;
        check("F1: ready at count 2", {63'b0, push_ready}, 64'd1);
        @(posedge clk); #1;
        check("F1: not ready at count 4 (full)", {63'b0, push_ready}, 64'd0);
        repeat (3) @(posedge clk);
        #1;
        check("F1: still full, source stalled", fpc, 64'h10);
        pop_en = 1'b1;
        repeat (20) @(posedge clk);
        #1;
        check("F1: all 8 instructions out", 64'(log_n), 64'd8);
        for (k = 0; k < 8; k++) begin
            check($sformatf("F1: order %0d pc", k), log_pc[k], 64'(4 * k));
            check($sformatf("F1: order %0d raw", k), {32'b0, log_raw[k]},
                  {32'b0, w32((k / 2 + 1) * 16 + (k % 2))});
        end

        // ---- F2: flush empties the queue ----
        flush_all(64'h0);
        flimit = 64'h8;
        src_en = 1'b1;
        @(posedge clk); #1;
        check("F2: non-empty before flush", {63'b0, head_valid}, 64'd1);
        flush_all(64'h0);
        check("F2: empty after flush", {63'b0, head_valid}, 64'd0);
        check("F2: ready after flush", {63'b0, push_ready}, 64'd1);

        // ---- F3: a pop while empty is ignored, not an underflow ----
        force_pop = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        force_pop = 1'b0;
        check("F3: still empty after popping an empty queue", {63'b0, head_valid}, 64'd0);
        check("F3: still ready after popping an empty queue", {63'b0, push_ready}, 64'd1);
        flimit = 64'h8;
        src_en = 1'b1;
        pop_en = 1'b1;
        repeat (6) @(posedge clk);
        #1;
        check("F3: exactly the 2 pushed entries come out", 64'(log_n), 64'd2);
        check("F3: first entry", {32'b0, log_raw[0]}, {32'b0, w32(16)});
        check("F3: second entry", {32'b0, log_raw[1]}, {32'b0, w32(17)});
        check("F3: empty again", {63'b0, head_valid}, 64'd0);

        $display("");
        $display("qv_align_fifo_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_align_fifo_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT: qv_align_fifo_tb");
        $finish;
    end
endmodule
