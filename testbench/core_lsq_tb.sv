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
    // (O5a) with the D$ inside the core a load may be answered from a line refilled for another load, or after the
    // store buffer updated it: the bus order checks become relations (the store reached memory; the last read of a
    // dword behind a write past the buffer comes after that write, since the write empties the line)
    localparam bit DC_ON = (`QV_PIPE_DCACHE != 0);

    `include "core_ideal_env.svh"

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
        if (DC_ON)
            check("A: the store reached memory (the load is answered from the D$ the drain updated)",
                  b(first_acc(32'h1000, 1'b1) >= 0), 64'd1);
        else
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
        emit(encode_b(8 * 4, 5'd5, 5'd5, 3'b000, `OPC_BRANCH));         // beq x5, x5, +32 (taken; predicted not taken; it waits
                                                                        // for the DIV, so the wrong path runs even when the core recovers at execute)
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
        if (DC_ON)
            check("G: the load behind the SC read its line again after the SC's write (the SC emptied it)",
                  b(last_acc(32'h1038, 1'b0) > first_acc(32'h1030, 1'b1)), 64'd1);
        else
            check("G: the load behind the SC read only after its write", b(first_acc(32'h1038, 1'b0) > first_acc(32'h1030, 1'b1)), 64'd1);
        check("G: the load behind the SC: its dword", x(23), init_word((32'h1038) >> 3));
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
