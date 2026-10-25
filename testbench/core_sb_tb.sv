// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, the store buffer (P9d), end to end on core_wb4_sram_harness (whose RAM window is the whole
 * SRAM, so every store to it is posted and written to the bus only after it has retired).
 *
 * Run 1, one straight program that checks what the buffer must get right:
 *   - a load behind a store to the same dword, at every size and byte offset, with lanes merged into a dword
 *     already stored (a load reads memory, so it must wait for the buffered store to land, never see old data);
 *   - an AMO and an LR/SC pair right behind stores to their dword (atomics wait for an empty buffer);
 *   - self-modifying code: a store into the code, then FENCE.I, then a jump to it (FENCE.I waits for the buffer);
 *   - a store outside the RAM window (a bus error): it is not posted, so the access fault is precise, taken at the
 *     faulting store's own pc with every store before it already in memory;
 *   - EBREAK as the end of the program: when its trap fires, the last stores right before it are in memory (the
 *     tests that read memory at the trap, perf_tb and the toolchain ones, rely on it).
 * Run 2: a halt request right after a run of stores. The hart is halted internally at once, but o_debug_mode
 * (what the Debug Module reads) rises only once the buffer is empty, with all the stores in memory.
 */
module core_sb_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic halt_req = 1'b0;
    logic o_debug_mode;

    core_wb4_sram_harness #(.NUM_WORDS(512)) dut (
        .clk(clk), .rst(rst), .i_debug_halt_req(halt_req), .o_debug_mode(o_debug_mode)
    );

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    // the test program is assembled into prog[]; instructions are 4 bytes
    logic [31:0] prog [0:1023];
    int          n;
    task automatic emit(input logic [31:0] w); prog[n] = w; n++; endtask
    function automatic int here(); return n * 4; endfunction

    task automatic load_image();
        for (int i = 0; i < 512; i++) dut.sram0.memory[i] = 64'b0;
        for (int i = 0; i < n; i += 2)
            dut.sram0.memory[i / 2] = {(i + 1 < n) ? prog[i + 1] : 32'h0, prog[i]};
    endtask

    localparam logic [63:0] K1 = 64'h8899_AABB_CCDD_EEFF;
    localparam logic [63:0] K2 = 64'h1122_3344_5566_7788;

    // x1 = data base, loaded constants
    localparam int R_BASE = 1, R_K1 = 2, R_K2 = 3;

    function automatic logic [31:0] i_(input int imm, input int rs1, input logic [2:0] f3, input int rd, input logic [6:0] opc);
        return encode_i(imm, rs1[4:0], f3, rd[4:0], opc);
    endfunction
    function automatic logic [31:0] st_(input int imm, input int rs2, input int rs1, input logic [2:0] f3);
        return encode_s(imm, rs2[4:0], rs1[4:0], f3, `OPC_STORE);
    endfunction
    function automatic logic [31:0] ld_(input int imm, input int rs1, input logic [2:0] f3, input int rd);
        return encode_i(imm, rs1[4:0], f3, rd[4:0], `OPC_LOAD);
    endfunction

    // ---- program 1 ----
    int pc_fault, pc_jal, pc_back;

    task automatic build_run1();
        n = 0;
        emit(i_(32'h400, 0, 3'b000, R_BASE, `OPC_OP_IMM));              // addi x1, x0, 0x400
        emit(ld_(32'h300, 0, 3'b011, R_K1));                            // ld   x2, 0x300(x0)   K1
        emit(ld_(32'h308, 0, 3'b011, R_K2));                            // ld   x3, 0x308(x0)   K2
        emit(i_(32'h600, 0, 3'b000, 6, `OPC_OP_IMM));                   // addi x6, x0, 0x600
        emit(encode_csr(`CSR_MTVEC, 5'd6, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM));   // csrw mtvec, x6
        // T1: the same dword, every size
        emit(st_(0, R_K1, R_BASE, 3'b011));                             // sd   x2, 0(x1)
        emit(ld_(0, R_BASE, 3'b000, 10));                               // lb   x10, 0(x1)
        emit(ld_(1, R_BASE, 3'b100, 11));                               // lbu  x11, 1(x1)
        emit(ld_(2, R_BASE, 3'b001, 12));                               // lh   x12, 2(x1)
        emit(ld_(4, R_BASE, 3'b010, 13));                               // lw   x13, 4(x1)
        emit(ld_(0, R_BASE, 3'b011, 14));                               // ld   x14, 0(x1)
        emit(st_(3, R_K2, R_BASE, 3'b000));                             // sb   x3, 3(x1)
        emit(ld_(0, R_BASE, 3'b110, 15));                               // lwu  x15, 0(x1)
        emit(st_(4, R_K2, R_BASE, 3'b001));                             // sh   x3, 4(x1)
        emit(ld_(4, R_BASE, 3'b101, 16));                               // lhu  x16, 4(x1)
        emit(ld_(0, R_BASE, 3'b011, 17));                               // ld   x17, 0(x1)
        emit(st_(0, R_K2, R_BASE, 3'b010));                             // sw   x3, 0(x1)
        emit(ld_(0, R_BASE, 3'b011, 18));                               // ld   x18, 0(x1)
        // T8: atomics right behind stores
        emit(st_(8, R_K1, R_BASE, 3'b011));                             // sd   x2, 8(x1)
        emit(i_(1, 0, 3'b000, 4, `OPC_OP_IMM));                         // addi x4, x0, 1
        emit(i_(8, R_BASE, 3'b000, 7, `OPC_OP_IMM));                    // addi x7, x1, 8
        emit(encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd4, 5'd7, `FUNCT3_AMO_D, 5'd19, `OPC_AMO));   // amoadd.d x19, x4, (x7)
        emit(ld_(8, R_BASE, 3'b011, 20));                               // ld   x20, 8(x1)
        emit(st_(16, R_K2, R_BASE, 3'b011));                            // sd   x3, 16(x1)
        emit(i_(16, R_BASE, 3'b000, 7, `OPC_OP_IMM));                   // addi x7, x1, 16
        emit(encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0, 5'd7, `FUNCT3_AMO_D, 5'd21, `OPC_AMO));       // lr.d x21, (x7)
        emit(encode_amo(`FUNCT5_SC, 1'b0, 1'b0, 5'd4, 5'd7, `FUNCT3_AMO_D, 5'd22, `OPC_AMO));       // sc.d x22, x4, (x7)
        emit(ld_(16, R_BASE, 3'b011, 23));                              // ld   x23, 16(x1)
        // T2: self-modifying code
        emit(ld_(32'h310, 0, 3'b010, 5));                               // lw   x5, 0x310(x0)   the new instruction
        emit(st_(32'h200, 5, 0, 3'b010));                               // sw   x5, 0x200(x0)
        emit(32'h0000_100F);                                            // fence.i
        pc_jal = here();
        emit(encode_j(32'h200 - pc_jal, 5'd0, `OPC_JAL));               // jal  x0, 0x200
        pc_back = here();
        // T9: a store outside the window, behind a posted one
        emit(st_(24, R_K1, R_BASE, 3'b011));                            // sd   x2, 24(x1)
        emit(encode_u(20'd1, 5'd8, `OPC_LUI));                          // lui  x8, 1           x8 = 0x1000
        pc_fault = here();
        emit(st_(0, R_K1, 8, 3'b011));                                  // sd   x2, 0(x8)       bus error: access fault
        // and the program's last stores right before its EBREAK
        emit(st_(32, R_K1, R_BASE, 3'b011));                            // sd   x2, 32(x1)
        emit(st_(40, R_K2, R_BASE, 3'b011));                            // sd   x3, 40(x1)
        emit(32'h0010_0073);                                            // ebreak
        // the patched site and the trap handler
        while (n < 32'h200 / 4) emit(32'h0000_0013);
        emit(i_(1, 0, 3'b000, 24, `OPC_OP_IMM));                        // addi x24, x0, 1     (patched to x24 = 2)
        emit(encode_j(pc_back - here(), 5'd0, `OPC_JAL));               // jal  x0, back
        while (n < 32'h600 / 4) emit(32'h0000_0013);
        emit(encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd26, `OPC_SYSTEM));     // csrr x26, mcause
        emit(encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd27, `OPC_SYSTEM));       // csrr x27, mepc
        emit(i_(4, 27, 3'b000, 28, `OPC_OP_IMM));                       // addi x28, x27, 4
        emit(encode_csr(`CSR_MEPC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM));       // csrw mepc, x28
        emit(`INSTR_HEX_MRET);                                          // mret
    endtask

    task automatic reset_and_run(input int limit);
        rst = 1'b1;
        repeat (4) @(posedge clk);
        #1;
        load_image();
        dut.sram0.memory[8'h60] = K1;                                   // 0x300
        dut.sram0.memory[8'h61] = K2;                                   // 0x308
        dut.sram0.memory[8'h62] = {32'h0, i_(2, 0, 3'b000, 24, `OPC_OP_IMM)};   // 0x310: addi x24, x0, 2
        @(posedge clk); #1;
        rst = 1'b0;
    endtask

    logic halted = 1'b0;
    always @(posedge clk) if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"

    function automatic logic [63:0] x(input int r); return dut.core0.regfile0.gp_registers[r]; endfunction

    initial begin
        // ================= run 1 =================
        build_run1();
        reset_and_run(0);
        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "run 1: EBREAK trap never fired");
        // the trap pulse is here: everything stored before the EBREAK must be in memory already
        check("run 1: the last store before EBREAK is in memory at the EBREAK trap", dut.sram0.memory[8'h85], K2);
        check("run 1: ... and the one before it", dut.sram0.memory[8'h84], K1);

        check("sd then lb",  x(10), 64'hFFFF_FFFF_FFFF_FFFF);
        check("sd then lbu at +1", x(11), 64'hEE);
        check("sd then lh at +2", x(12), 64'hFFFF_FFFF_FFFF_CCDD);
        check("sd then lw at +4", x(13), 64'hFFFF_FFFF_8899_AABB);
        check("sd then ld", x(14), K1);
        check("sb merged into the dword, then lwu", x(15), 64'h0000_0000_88DD_EEFF);
        check("sh merged, then lhu", x(16), 64'h7788);
        check("... and the whole dword", x(17), 64'h8899_7788_88DD_EEFF);
        check("sw merged, then ld", x(18), 64'h8899_7788_5566_7788);
        check("AMO right behind a store reads the stored value", x(19), K1);
        check("... and its result is in memory", x(20), K1 + 64'd1);
        check("LR right behind a store reads the stored value", x(21), K2);
        check("SC succeeds", x(22), 64'd0);
        check("... and wrote", x(23), 64'd1);
        check("self-modifying code: FENCE.I after the store runs the new instruction", x(24), 64'd2);
        check("the store outside the window: access fault", x(26), 64'd7);
        check("... precise, at the faulting store's own pc", x(27), 64'(pc_fault));
        check("... the posted store before it landed", dut.sram0.memory[8'h83], K1);
        check("the code was patched in memory", dut.sram0.memory[8'h40][31:0], i_(2, 0, 3'b000, 24, `OPC_OP_IMM));
        check("dword 0x400: the lanes merged in memory", dut.sram0.memory[8'h80], 64'h8899_7788_5566_7788);

        // ================= run 2: a halt request after stores =================
        halted = 1'b0;
        n = 0;
        emit(i_(32'h400, 0, 3'b000, R_BASE, `OPC_OP_IMM));              // addi x1, x0, 0x400
        emit(ld_(32'h300, 0, 3'b011, R_K1));                            // ld   x2, 0x300(x0)
        emit(st_(0,  R_K1, R_BASE, 3'b011));
        emit(st_(8,  R_K1, R_BASE, 3'b011));
        emit(st_(16, R_K1, R_BASE, 3'b011));
        emit(st_(24, R_K1, R_BASE, 3'b011));                            // the 4th store: pc = 0x14
        for (int i = 0; i < 40; i++) emit(32'h0000_0013);               // nops
        emit(32'h0010_0073);
        reset_and_run(0);
        begin
            int  c, t_int, t_ext;
            logic seen_int, seen_ext;
            seen_int = 1'b0; seen_ext = 1'b0; t_int = -1; t_ext = -1;
            for (c = 0; c < 400 && !seen_ext; c++) begin
                @(posedge clk); #1;
                // the halt request goes up as the 4th store retires
                if (dut.core0.commit_now_w && dut.core0.c_pc_rdata === 64'h14) halt_req = 1'b1;
                if (!seen_int && dut.core0.in_debug_mode) begin seen_int = 1'b1; t_int = c; end
                if (!seen_ext && o_debug_mode) begin seen_ext = 1'b1; t_ext = c; end
            end
            check("run 2: the hart halted", {63'b0, seen_int}, 64'd1);
            check("run 2: and showed as halted", {63'b0, seen_ext}, 64'd1);
            check("run 2: it showed after the stores had drained (not before the hart halted)", 64'(t_ext >= t_int), 64'd1);
            check("run 2: the buffer is empty when it shows", {63'b0, dut.core0.sb_empty}, 64'd1);
            check("run 2: store 1 in memory", dut.sram0.memory[8'h80], K1);
            check("run 2: store 2 in memory", dut.sram0.memory[8'h81], K1);
            check("run 2: store 3 in memory", dut.sram0.memory[8'h82], K1);
            check("run 2: store 4 in memory", dut.sram0.memory[8'h83], K1);
            check("run 2: the exported halt lagged the internal one while the buffer drained", 64'(t_ext > t_int), 64'd1);
        end

        $display("");
        $display("core_sb_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sb_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
