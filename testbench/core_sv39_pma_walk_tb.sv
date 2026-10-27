// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: a page-table read outside RAM happens only for an instruction that
 * executes (P10d). The pipelined core walks for fetch speculatively, on wrong
 * paths too; a PTE read can have a side effect (a PLIC claim, a UART receive
 * register), so with a RAM window (core_wb4_sram_harness sets it to its SRAM) a
 * fetch-side read outside it waits until the fetch is on the architectural path.
 *
 * The map (Sv39, S mode): root[0] -> L1 at 0x2000; L1[2] -> L0 at 0x3000, whose
 * entry 0 maps the code page VA 0x0040_0000 to PA 0x5000; L1[1] -> a "table" at
 * PA 0x0010_0000, outside the 32 KB SRAM (a read there is a bus error). So the
 * walk of any VA in [0x0020_0000, 0x0040_0000) reads root, L1 (both RAM), then
 * an L0 entry outside RAM.
 *   A. the wrong path: div x1 (slow), then beq x1, x0 back to 0x003F_FFFC,
 *      predicted taken (backward) but not taken (x1 = 7). Fetch walks for the
 *      predicted target while the div runs; the walk must wait before the read
 *      outside RAM and be cancelled by the redirect: no read there at all, and
 *      the program goes on (x5 = 5).
 *   B. the real path: jal to 0x003F_FFFC. The walk waits until the jal has
 *      retired and nothing is left in flight, then reads -- exactly once -- and
 *      the bus error makes the fetch an access fault (mcause 1, mtval the VA).
 * Both run on the reference too (its FSM walks only for the instruction it
 * executes); the checks on the walker's wait are the pipelined core's.
 *
 * Killed by: a walker without the wait, and a core whose test of the real path
 * ignores the ROB. Its other terms (the decode register, the instruction queue,
 * the fetch buffer) are not isolated here: an older instruction leaves them for
 * the ROB within about two cycles of the prediction, before any walk reaches its
 * third read, so the ROB term already holds the read back (qv_ptw_tb tests the
 * wait itself with i_f_nonspec free).
 */
module core_sv39_pma_walk_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst;

    function automatic logic [31:0] enc_or(input logic [4:0] rd, rs1, rs2);
        return encode_r(7'b0000000, rs2, rs1, 3'b110, rd, `OPC_OP);
    endfunction
    function automatic logic [31:0] enc_div(input logic [4:0] rd, rs1, rs2);
        return encode_r(7'b0000001, rs2, rs1, 3'b100, rd, `OPC_OP);
    endfunction
    function automatic logic [31:0] enc_addi(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b000, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_slli(input logic [4:0] rd, rs1, input logic [5:0] shamt);
        return encode_shift64(6'b0, shamt, rs1, 3'b001, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_csrrw(input logic [11:0] csr, input logic [4:0] rs1);
        return encode_csr(csr, rs1, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_csrr(input logic [4:0] rd, input logic [11:0] csr);
        return encode_csr(csr, 5'd0, 3'b010, rd, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_lui(input logic [4:0] rd, input logic [19:0] imm20);
        return {imm20, rd, `OPC_LUI};
    endfunction
    function automatic logic [31:0] enc_beq(input logic [4:0] rs1, rs2, input int imm);
        return encode_b(imm, rs2, rs1, 3'b000, `OPC_BRANCH);
    endfunction
    function automatic logic [31:0] enc_jal(input logic [4:0] rd, input int imm);
        return encode_j(imm, rd, `OPC_JAL);
    endfunction
    localparam logic [31:0] EBREAK_INSN = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM};
    localparam logic [31:0] NOP_INSN    = 32'h00000013;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_a (.clk(clk), .rst(rst));
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_b (.clk(clk), .rst(rst));

    // the run ends at the first EBREAK trap (a's in S, b's in the M handler); the registers are read then
    logic halted_a = 1'b0, halted_b = 1'b0;
    logic [63:0] a_x5, b_x6, b_x7;
    always @(posedge clk) if (!halted_a && dut_a.core0.trap_taken && dut_a.core0.is_ebreak) begin
        halted_a <= 1'b1; a_x5 <= dut_a.core0.regfile0.gp_registers[5];
    end
    always @(posedge clk) if (!halted_b && dut_b.core0.trap_taken && dut_b.core0.is_ebreak) begin
        halted_b <= 1'b1; b_x6 <= dut_b.core0.regfile0.gp_registers[6]; b_x7 <= dut_b.core0.regfile0.gp_registers[7];
    end
    wire halted = halted_a && halted_b;
    `include "halt_wait.sv"

    // reads of the page outside RAM where the L1 pointer leads, on the shared SRAM bus
    int outside_a = 0, outside_b = 0;
    logic pa_cyc = 1'b0, pb_cyc = 1'b0;
    always @(posedge clk) begin
        if (!rst && dut_a.wb_cyc && dut_a.wb_stb && !pa_cyc && dut_a.wb_addr[31:12] == 20'h00100) outside_a++;
        if (!rst && dut_b.wb_cyc && dut_b.wb_stb && !pb_cyc && dut_b.wb_addr[31:12] == 20'h00100) outside_b++;
        pa_cyc <= dut_a.wb_cyc && dut_a.wb_stb;
        pb_cyc <= dut_b.wb_cyc && dut_b.wb_stb;
    end
`ifndef QV_REF_AS_CORE
    // A: the wrong path really was walked for, and the walker waited before the read outside RAM
    bit a_walked = 1'b0, a_waited = 1'b0;
    always @(posedge clk) if (!rst) begin
        if (dut_a.core0.g_sv39.ptw0.accept_f && dut_a.core0.g_sv39.ptw0.i_f_va[63:12] == 52'h003FF) a_walked <= 1'b1;
        if (dut_a.core0.g_sv39.ptw0.st_q == 2'd1 && dut_a.core0.g_sv39.ptw0.f_wait) a_waited <= 1'b1;
    end
`endif

    task automatic setup(input int which);
        logic [63:0] w [0:8];
        begin
            // M mode: satp = Sv39, root at PPN 1; MPP = S; mepc = VA 0x0040_0000; mtvec = the handler at 0x100; mret
            w[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
            w[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
            w[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
            w[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
            w[4] = {enc_csrrw(`CSR_MEPC,5'd4), enc_lui(5'd4,20'h00400)};
            w[5] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
            w[6] = {NOP_INSN, `INSTR_HEX_MRET};
            // the M handler: mcause, mtval, then EBREAK (the end)
            w[7] = {enc_csrr(5'd7,`CSR_MTVAL), enc_csrr(5'd6,`CSR_MCAUSE)};
            w[8] = {NOP_INSN, EBREAK_INSN};
            for (int i = 0; i < 7; i++) begin
                if (which == 0) dut_a.sram0.memory[i] = w[i]; else dut_b.sram0.memory[i] = w[i];
            end
            for (int i = 0; i < 2; i++) begin
                if (which == 0) dut_a.sram0.memory[32 + i] = w[7 + i]; else dut_b.sram0.memory[32 + i] = w[7 + i];
            end
            // the tables: root (PPN 1), L1 (PPN 2), L0 (PPN 3); L1[1] points outside RAM
            if (which == 0) begin
                dut_a.sram0.memory[512 + 0]  = 64'h801;                  // root[0] -> L1
                dut_a.sram0.memory[1024 + 1] = 64'h40001;                // L1[1]   -> PA 0x0010_0000
                dut_a.sram0.memory[1024 + 2] = 64'hC01;                  // L1[2]   -> L0
                dut_a.sram0.memory[1536 + 0] = 64'h14CF;                 // L0[0]   -> PA 0x5000, V R W X A D
            end else begin
                dut_b.sram0.memory[512 + 0]  = 64'h801;
                dut_b.sram0.memory[1024 + 1] = 64'h40001;
                dut_b.sram0.memory[1024 + 2] = 64'hC01;
                dut_b.sram0.memory[1536 + 0] = 64'h14CF;
            end
        end
    endtask

    initial begin
        rst = 1;
        #1;
        setup(0);
        setup(1);
        // A, at VA 0x0040_0000 (PA 0x5000): x1 = 7 / 1 (slow), then a backward branch on it, predicted taken, not taken
        dut_a.sram0.memory[2560 + 0] = {enc_addi(5'd3,5'd0,1), enc_addi(5'd2,5'd0,7)};
        dut_a.sram0.memory[2560 + 1] = {enc_beq(5'd1,5'd0,-16), enc_div(5'd1,5'd2,5'd3)};     // the beq at 0xC -> 0x003F_FFFC
        dut_a.sram0.memory[2560 + 2] = {EBREAK_INSN, enc_addi(5'd5,5'd0,5)};
        // B: jal to 0x003F_FFFC, the instruction fetch faults there for real
        dut_b.sram0.memory[2560 + 0] = {NOP_INSN, enc_jal(5'd0, -4)};

        @(posedge clk); #1;
        rst = 0;
        wait_halted_or_timeout(20000, "PMA walk test never halted");
        #1;

        check("A: the program went on past the mispredicted branch", a_x5, 64'd5);
        check("A: no read outside RAM for the wrong path", 64'(outside_a), 64'd0);
`ifndef QV_REF_AS_CORE
        check("A: fetch did walk for the wrong-path target", 64'(a_walked), 64'd1);
        check("A: ... and the walker waited before the read outside RAM", 64'(a_waited), 64'd1);
`endif
        check("B: the fetch on the real path read outside RAM exactly once", 64'(outside_b), 64'd1);
        check("B: ... and faulted: instruction access fault", b_x6, 64'd1);
        check("B: ... at the jump's target", b_x7, 64'h003F_FFFC);

        $display("");
        $display("core_sv39_pma_walk_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_pma_walk_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
