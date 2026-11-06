// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, Sv39 -- two things a pipelined core could get wrong that the
 * other core_sv39_*_tb files cannot show, via core_wb4_sram_harness (flat memory,
 * no cache). Both are architectural facts, so every core runs them.
 *
 *   A. A fetch that is not on the program's path never traps. S-mode code at the
 *      last dword of a mapped page jumps (JAL, predicted taken) to another
 *      address; the dword after it, in the next virtual page, is unmapped. A
 *      core that fetches ahead translates that dword speculatively and gets a
 *      page fault it must drop with the wrong path: the program must see no
 *      trap at all (the M-mode handler records mcause into x20, which has to be
 *      the EBREAK's 3, and the code at the jump target has to have run).
 *
 *   B. A satp write does not flush the TLB; SFENCE.VMA does. S-mode code loads a
 *      data word (filling the TLB), rewrites that page's leaf PTE through an
 *      alias of the page-table page (the PTE now points at another physical
 *      page), writes satp back with its own value, and loads again: the cached
 *      translation still answers (the old data). After SFENCE.VMA the third
 *      load sees the new mapping (the new data). The code, the data page and the
 *      alias take three TLB entries, so no capacity effect comes into it.
 *
 * Layout shared by both: root @0x1000 (satp PPN 1), L1 @0x2000, L0 @0x3000;
 * VA 0x40403000.. is vpn2 = 1, vpn1 = 2, vpn0 = 3.. (as core_sv39_tlb_tb.sv).
 * M-mode setup: satp = Sv39/PPN 1, MPP = S, mepc = the entry VA, mtvec = 0x100,
 * mret. Handler @0x100: csrrs x20, mcause ; ebreak (every trap lands there; the
 * first EBREAK trap is what the testbench waits for, then the handler gets a
 * few hundred cycles to record mcause).
 */
module core_sv39_spec_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst;

    function automatic logic [31:0] enc_or(input logic [4:0] rd, rs1, rs2);
        return encode_r(7'b0000000, rs2, rs1, 3'b110, rd, `OPC_OP);
    endfunction
    function automatic logic [31:0] enc_addi(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b000, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_ori(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b110, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_slli(input logic [4:0] rd, rs1, input logic [5:0] shamt);
        return encode_shift64(6'b0, shamt, rs1, 3'b001, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_csrrw(input logic [11:0] csr, input logic [4:0] rs1, input logic [4:0] rd = 5'd0);
        return encode_csr(csr, rs1, `FUNCT3_CSRRW, rd, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_csrrs(input logic [11:0] csr, input logic [4:0] rd);
        return encode_csr(csr, 5'd0, `FUNCT3_CSRRS, rd, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_jal(input logic [4:0] rd, input int imm);
        return encode_j(imm, rd, `OPC_JAL);
    endfunction
    function automatic logic [31:0] enc_lui(input logic [4:0] rd, input logic [19:0] imm20);
        return {imm20, rd, `OPC_LUI};
    endfunction
    function automatic logic [31:0] enc_ld(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b011, rd, `OPC_LOAD);
    endfunction
    function automatic logic [31:0] enc_sd(input logic [4:0] rs2, rs1, input int imm);
        return encode_s(imm, rs2, rs1, 3'b011, `OPC_STORE);
    endfunction
    localparam logic [31:0] EBREAK_INSN = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM};
    localparam logic [31:0] NOP_INSN    = 32'h00000013;
    localparam logic [31:0] SFENCE_VMA_INSN = 32'h12000073;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_a (.clk(clk), .rst(rst));
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_b (.clk(clk), .rst(rst));
    logic halted_a = 1'b0, halted_b = 1'b0;
    always @(posedge clk) if (dut_a.core0.trap_taken && dut_a.core0.is_ebreak) halted_a <= 1'b1;
    always @(posedge clk) if (dut_b.core0.trap_taken && dut_b.core0.is_ebreak) halted_b <= 1'b1;
    wire halted = halted_a && halted_b;
    `include "halt_wait.sv"

    // the M-mode setup program, words 0-8, for an entry at VA = (high << 20) | (vpn0 << 12)
    task automatic setup(input int which, input int high, input int vpn0);
        logic [63:0] w [0:8];
        w[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        w[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        w[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        w[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        w[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,high)};
        w[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,vpn0)};
        w[6] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};
        w[7] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        w[8] = {NOP_INSN, `INSTR_HEX_MRET};
        for (int i = 0; i < 9; i++) begin
            if (which == 0) dut_a.sram0.memory[i] = w[i]; else dut_b.sram0.memory[i] = w[i];
        end
        // the handler: record mcause, then an EBREAK (again and again if it is entered more than once)
        if (which == 0) begin
            dut_a.sram0.memory[32] = {NOP_INSN, enc_csrrs(`CSR_MCAUSE,5'd20)};
            dut_a.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};
        end else begin
            dut_b.sram0.memory[32] = {NOP_INSN, enc_csrrs(`CSR_MCAUSE,5'd20)};
            dut_b.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};
        end
    endtask

    initial begin
        rst = 1;
        #1;

        /* ================= Test A: the dword after a taken jump is unmapped ================= */
        setup(0, 1028, 3);                                                // entry VA 0x40403000
        dut_a.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801;          // L2[1] -> L1@0x2000
        dut_a.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;          // L1[2] -> L0@0x3000
        dut_a.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;          // L0[3] -> PPN 4 (PA 0x4000), RWX AD, U=0
        // (L0[4], VA 0x40404000, stays zero: V=0)
        // entry @VA 0x40403000: jal x0, +0xFF8 (to the last dword of the page)
        dut_a.sram0.memory[2048] = {NOP_INSN, enc_jal(5'd0, 4088)};
        // last dword @VA 0x40403FF8 (PA 0x4FF8): jal x0, -0xEF8 (back to VA 0x40403100). The next dword, VA 0x40404000, is
        // unmapped: a core that fetches ahead faults on it, and must forget that with the wrong path.
        dut_a.sram0.memory[2559] = {NOP_INSN, enc_jal(5'd0, -3832)};
        // target @VA 0x40403100 (PA 0x4100): addi x11,x0,222 ; ebreak
        dut_a.sram0.memory[2080] = {EBREAK_INSN, enc_addi(5'd11,5'd0,222)};

        /* ================= Test B: a satp write does not flush, SFENCE.VMA does ================= */
        setup(1, 1028, 3);
        dut_b.sram0.memory[512 + 1]  = 64'h0000_0000_0000_0801;
        dut_b.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_b.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;          // L0[3] -> PPN 4: the code
        dut_b.sram0.memory[1536 + 5] = 64'h0000_0000_0000_14CF;          // L0[5] -> PPN 5 (PA 0x5000): the data page, VA 0x40405000
        dut_b.sram0.memory[1536 + 6] = 64'h0000_0000_0000_0CC7;          // L0[6] -> PPN 3 (the L0 table itself), R W A D: VA 0x40406000
        dut_b.sram0.memory[2560] = 64'h0000_0000_0000_1111;              // the data, PA 0x5000
        dut_b.sram0.memory[3072] = 64'h0000_0000_0000_2222;              // the other page's data, PA 0x6000
        // S-mode code @VA 0x40403000 (PA 0x4000): two instructions per word, low first
        dut_b.sram0.memory[2048 + 0] = {enc_lui(5'd9, 20'h40406), enc_lui(5'd6, 20'h40405)};   // x6 = data VA, x9 = alias VA
        dut_b.sram0.memory[2048 + 1] = {enc_addi(5'd10,5'd0,6), enc_ld(5'd5, 5'd6, 0)};        // x5 = old data (fills the TLB); x10 = 6
        dut_b.sram0.memory[2048 + 2] = {enc_ori(5'd10,5'd10,207), enc_slli(5'd10,5'd10,6'd10)};// x10 = (6 << 10) | 0xCF: the new PTE
        dut_b.sram0.memory[2048 + 3] = {enc_csrrs(`CSR_SATP,5'd12), enc_sd(5'd10, 5'd9, 40)};  // L0[5] := new PTE ; x12 = satp
        dut_b.sram0.memory[2048 + 4] = {enc_ld(5'd7, 5'd6, 0), enc_csrrw(`CSR_SATP,5'd12)};    // satp := satp ; x7 = data again
        dut_b.sram0.memory[2048 + 5] = {enc_ld(5'd8, 5'd6, 0), SFENCE_VMA_INSN};               // sfence.vma ; x8 = data once more
        dut_b.sram0.memory[2048 + 6] = {NOP_INSN, EBREAK_INSN};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "Sv39 spec test never halted");
        repeat (400) @(posedge clk);
        #1;

        // ---- Test A ----
        check("A: the code at the jump target ran (x11==222)", dut_a.core0.regfile0.gp_registers[11], 64'd222);
        check("A: the only trap was the EBREAK (mcause==3): the fetch past the jump never trapped",
              dut_a.core0.regfile0.gp_registers[20], 64'd3);

        // ---- Test B ----
        check("B: the first load saw the old data", dut_b.core0.regfile0.gp_registers[5], 64'h1111);
        check("B: after a satp write the cached translation still answered (old data)", dut_b.core0.regfile0.gp_registers[7], 64'h1111);
        check("B: after SFENCE.VMA the new mapping is used (new data)", dut_b.core0.regfile0.gp_registers[8], 64'h2222);
        check("B: nothing trapped but the EBREAK", dut_b.core0.regfile0.gp_registers[20], 64'd3);

        $display("");
        $display("core_sv39_spec_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_spec_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
