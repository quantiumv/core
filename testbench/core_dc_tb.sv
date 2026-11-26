// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, the D$ inside the core (O5a, QV_PIPE_DCACHE), end to end. The harness is core_lsq_tb's
 * (core_ideal_env.svh): fetch from an ideal port, the memory port on a slave with DW wait states, every access logged,
 * one memory of 8 KiB that is all
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

    `include "core_ideal_env.svh"

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
