// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, Sv39 Milestone 4 -- mem-side (load/store/AMO)
 * translation, via core_wb4_sram_harness. Mirrors core_sv39_fetch_tb.sv's
 * own structure/conventions exactly (same M-mode-setup idiom, same
 * hand-packed page-table construction, same scope-narrowing discipline).
 *
 * Four tests, covering the pieces genuinely new to this milestone (the
 * walker itself, its leaf-detection/superpage machinery, and the PMP-
 * after-translation two-tier ordering were all already proven by
 * core_sv39_fetch_tb.sv -- this file exercises the mem-specific
 * additions on top of that proven base):
 *   A. Load+store round trip through a translated 4KB page -- proves
 *      mem_paddr's own translated mux drives BOTH read and write bus
 *      transactions correctly.
 *   B. AMOADD.D through translation -- proves the "AMO write phase
 *      reuses the read phase's own translated PA, no second walk"
 *      design (amo_addr_q captures mem_paddr, already translated, with
 *      zero code change at the S_AMO_WRITE site).
 *   C. A page fault on a STORE to a read-only (W=0) page -- proves
 *      cause 15 (store/AMO page fault, not 13), mtval == the faulting VA.
 *   D. A PMP-denied PTE read specifically for the MEM stream (the
 *      CODE's own, separate walk succeeds; only the DATA target's own
 *      walk hits a denied PTE) -- proves cause 5 (load access fault),
 *      not 13, and proves decision 10's two-tier ordering exercised via
 *      the mem stream specifically (core_sv39_fetch_tb.sv's own test D
 *      only ever exercised it via the fetch stream).
 *
 * Deliberately deferred to a later pass, same discipline as the fetch
 * milestone's own test file: SUM=0/1 differentiation, MXR=0/1
 * differentiation, LR/SC through translation, and the AMO-vs-plain-load
 * page-fault classification edge case -- each a cheap, mechanical
 * variation of an already-proven mechanism here, not a new one.
 */
module core_sv39_mem_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst;

    localparam logic [2:0] FUNCT3_OR = 3'b110;
    localparam logic [6:0] FUNCT7_OR = 7'b0000000;
    function automatic logic [31:0] enc_or(input logic [4:0] rd, rs1, rs2);
        return encode_r(FUNCT7_OR, rs2, rs1, FUNCT3_OR, rd, `OPC_OP);
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
    function automatic logic [31:0] enc_csrrs(input logic [11:0] csr, input logic [4:0] rd);
        return encode_csr(csr, 5'd0, `FUNCT3_CSRRS, rd, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_ld(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b011, rd, `OPC_LOAD);
    endfunction
    function automatic logic [31:0] enc_sd(input logic [4:0] rs2, rs1, input int imm);
        return encode_s(imm, rs2, rs1, 3'b011, `OPC_STORE);
    endfunction
    function automatic logic [31:0] enc_amoadd_d(input logic [4:0] rd, rs1, rs2);
        return encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, rs2, rs1, `FUNCT3_AMO_D, rd, `OPC_AMO);
    endfunction
    localparam logic [31:0] EBREAK_INSN = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM};
    localparam logic [31:0] NOP_INSN    = 32'h00000013;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    /* ----------------------------------------------------------------
     * Shared page-table shape (all 4 tests): VA 0x40403000 (vpn2=1,
     * vpn1=2, vpn0=3, offset=0) -> L2@0x1000 entry1 -> L1@0x2000 entry2
     * -> L0@0x3000 entry3 -> leaf PPN=4 (PA 0x4000), the CODE page. Test
     * C additionally maps VA 0x40404000 (same vpn2/vpn1, vpn0=4) via
     * L0's own entry4 -> leaf PPN=5 (PA 0x5000), a separate DATA page.
     * Test D additionally maps VA 0x40400000 (vpn0=0) via L0's own
     * entry0, whose own PTE read is PMP-denied.
     * ---------------------------------------------------------------- */

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_a (.clk(clk), .rst(rst));
    logic halted_a = 1'b0;
    always @(posedge clk) if (dut_a.core0.trap_taken && dut_a.core0.is_ebreak) halted_a <= 1'b1;

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_b (.clk(clk), .rst(rst));
    logic halted_b = 1'b0;
    always @(posedge clk) if (dut_b.core0.trap_taken && dut_b.core0.is_ebreak) halted_b <= 1'b1;

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_c (.clk(clk), .rst(rst));
    logic halted_c = 1'b0;
    always @(posedge clk) if (dut_c.core0.trap_taken && dut_c.core0.is_ebreak) halted_c <= 1'b1;
    logic [63:0] mcause_c, mtval_c;
    logic        captured_c = 1'b0;
    always @(posedge clk) if (!captured_c && dut_c.core0.commit_now && dut_c.core0.pc == 64'h108) begin
        captured_c <= 1'b1;
        mcause_c   <= dut_c.core0.regfile0.gp_registers[20];
        mtval_c    <= dut_c.core0.regfile0.gp_registers[21];
    end

    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut_d (.clk(clk), .rst(rst));
    logic halted_d = 1'b0;
    always @(posedge clk) if (dut_d.core0.trap_taken && dut_d.core0.is_ebreak) halted_d <= 1'b1;
    logic [63:0] mcause_d, mtval_d;
    logic        captured_d = 1'b0;
    always @(posedge clk) if (!captured_d && dut_d.core0.commit_now && dut_d.core0.pc == 64'h108) begin
        captured_d <= 1'b1;
        mcause_d   <= dut_d.core0.regfile0.gp_registers[20];
        mtval_d    <= dut_d.core0.regfile0.gp_registers[21];
    end

    wire halted = halted_a && halted_b && halted_c && halted_d;
    `include "halt_wait.sv"

    initial begin
        rst = 1;
        #1; // run after wb4_sram's own time-0 init

        /*
         * ---- Test A: load+store round trip ----
         * M-mode setup (0x00-0x44, 9 words) -- identical shape to
         * core_sv39_fetch_tb.sv's own test A, plus one extra ADDI
         * building the store sentinel (x8=555):
         *  0x00-0x1C: satp (MODE=Sv39,PPN=1) + mstatus (MPP=S), as before.
         *  0x20 addi x8,x0,555        (store sentinel)
         *  0x24-0x38: VA=0x40403000 built into x4, as before.
         *  0x3C csrrw mepc,x4   0x40 addi x6,x0,0x100   csrrw mtvec,x6
         *  0x44 mret
         * S-mode code @0x4000 (VA 0x40403000): sd x8,0x100(x4) ;
         * ld x30,0x100(x4) ; ebreak -- round-trips through the SAME
         * translated leaf page's own data region (PA 0x4100).
         */
        dut_a.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_a.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_a.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_a.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_a.sram0.memory[4] = {enc_addi(5'd4,5'd0,1028), enc_addi(5'd8,5'd0,555)};
        dut_a.sram0.memory[5] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_a.sram0.memory[6] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_a.sram0.memory[7] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_a.sram0.memory[8] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_a.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801; // L2 entry1 -> L1@0x2000
        dut_a.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01; // L1 entry2 -> L0@0x3000
        dut_a.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0 entry3 -> leaf PPN=4, RWX=1
        dut_a.sram0.memory[2048] = {enc_ld(5'd30,5'd4,256), enc_sd(5'd8,5'd4,256)}; // 0x4004/0x4000
        dut_a.sram0.memory[2049] = {NOP_INSN, EBREAK_INSN};                        // 0x400C/0x4008

        /*
         * ---- Test B: AMOADD.D through translation ----
         * Same satp/mstatus/mepc/mtvec/mret shape, plus x12 (= VA+0x100,
         * the AMO's own rs1 -- AMO addressing has no immediate offset)
         * and x11 (= 50, the operand). Old value 100 pre-seeded at PA
         * 0x4100; AMOADD returns the OLD value into x9 and leaves
         * 100+50=150 at the SAME physical location -- reloaded via an
         * ordinary LD (x30) to prove the write phase landed at the
         * correct, translated address with no second walk.
         */
        dut_b.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_b.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_b.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_b.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_b.sram0.memory[4] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};
        dut_b.sram0.memory[5] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};
        dut_b.sram0.memory[6] = {enc_addi(5'd12,5'd4,256), enc_or(5'd4,5'd4,5'd5)};
        dut_b.sram0.memory[7] = {enc_csrrw(`CSR_MEPC,5'd4), enc_addi(5'd11,5'd0,50)};
        dut_b.sram0.memory[8] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};
        dut_b.sram0.memory[9] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_b.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_b.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_b.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF;
        dut_b.sram0.memory[2048] = {enc_ld(5'd30,5'd12,0), enc_amoadd_d(5'd9,5'd12,5'd11)}; // 0x4004/0x4000
        dut_b.sram0.memory[2049] = {NOP_INSN, EBREAK_INSN};
        dut_b.sram0.memory[2080] = 64'd100; // PA 0x4100 -- AMO's own OLD value

        /*
         * ---- Test C: store page fault (W=0), cause 15 ----
         * CODE stays on the vpn0=3 leaf (RWX=1, as tests A/B). A SEPARATE
         * leaf at vpn0=4 (VA 0x40404000, PA 0x5000) is mapped READ-ONLY
         * (R=1,W=0,X=0) via L0's own entry4 -- the store below targets
         * THAT page, not the code page, so X/W don't conflict with
         * fetch's own need for X=1 on the code page. x13 = VA
         * 0x40404000 (no low-order OR needed -- offset=0, vpn1/vpn0 both
         * exactly represented by a single shift).
         */
        dut_c.sram0.memory[0] = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};
        dut_c.sram0.memory[1] = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};
        dut_c.sram0.memory[2] = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};
        dut_c.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)};
        dut_c.sram0.memory[4] = {enc_slli(5'd13,5'd13,6'd20), enc_addi(5'd13,5'd0,1028)};
        dut_c.sram0.memory[5] = {enc_slli(5'd14,5'd14,6'd12), enc_addi(5'd14,5'd0,4)};
        dut_c.sram0.memory[6] = {enc_addi(5'd4,5'd0,1028), enc_or(5'd13,5'd13,5'd14)};
        dut_c.sram0.memory[7] = {enc_addi(5'd5,5'd0,3), enc_slli(5'd4,5'd4,6'd20)};
        dut_c.sram0.memory[8] = {enc_or(5'd4,5'd4,5'd5), enc_slli(5'd5,5'd5,6'd12)};
        dut_c.sram0.memory[9] = {enc_addi(5'd6,5'd0,256), enc_csrrw(`CSR_MEPC,5'd4)};
        dut_c.sram0.memory[10] = {`INSTR_HEX_MRET, enc_csrrw(`CSR_MTVEC,5'd6)};
        dut_c.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_c.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_c.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0 entry3 (code) -> PPN=4, RWX=1
        dut_c.sram0.memory[1536 + 4] = 64'h0000_0000_0000_1443; // L0 entry4 (data) -> PPN=5, R=1,W=0,X=0
        dut_c.sram0.memory[2048] = {EBREAK_INSN, enc_sd(5'd0,5'd13,0)}; // 0x4004=ebreak(unreached), 0x4000=sd x0,0(x13)
        dut_c.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_c.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        /*
         * ---- Test D: PMP-denied PTE read, mem stream, cause 5 ----
         * CODE's own walk (vpn0=3, as always) is fully permitted. A
         * SEPARATE, unrelated leaf at vpn0=0 (VA 0x40400000) is mapped
         * via L0's own entry0 (byte address 0x3000 exactly -- the
         * SAME address as L0's own table base, a harmless coincidence
         * of using index 0) -- content is irrelevant, since PMP denies
         * reading this ONE PTE before its content is ever consulted.
         * region0: TOR [0,0x3000), R=1 (permits L2/L1's own PTEs, both
         * < 0x3000; M-mode's own setup-code fetch is separately exempt
         * regardless, since this region is unlocked).
         * region1: TOR [0x3000,0x3008), R=0 -- denies ONLY entry0.
         * region2: TOR [0x3008, big), R=1 AND X=1 -- permits entry3's
         * own PTE read (0x3018) AND, separately, the CODE leaf's own
         * TRANSLATED fetch (PA 0x4000 also falls in this same region --
         * a real, empirically-caught test-design gap: PMP is one flat
         * region set governing BOTH a PTE read and the final resolved
         * address per decision 10's own two-tier ordering, so granting
         * only R here [enough for the PTE read] left the CODE's own
         * post-translation fetch denied by the EXISTING, already-proven
         * fetch-side PMP check -- X had to be added too).
         */
        dut_d.sram0.memory[0]  = {enc_slli(5'd1,5'd1,6'd60), enc_addi(5'd1,5'd0,8)};        // 0x04/0x00
        dut_d.sram0.memory[1]  = {enc_or(5'd1,5'd1,5'd2), enc_addi(5'd2,5'd0,1)};           // 0x0C/0x08
        dut_d.sram0.memory[2]  = {enc_addi(5'd3,5'd0,1), enc_csrrw(`CSR_SATP,5'd1)};        // 0x14/0x10
        dut_d.sram0.memory[3]  = {enc_csrrw(`CSR_MSTATUS,5'd3), enc_slli(5'd3,5'd3,6'd11)}; // 0x1C/0x18
        dut_d.sram0.memory[4]  = {enc_slli(5'd7,5'd7,6'd10), enc_addi(5'd7,5'd0,3)};        // 0x24/0x20 -- x7=3072=pmpaddr0
        dut_d.sram0.memory[5]  = {enc_addi(5'd8,5'd7,2), enc_csrrw(`CSR_PMPADDR0,5'd7)};    // 0x2C/0x28 -- x8=3074=pmpaddr1
        dut_d.sram0.memory[6]  = {enc_addi(5'd9,5'd0,2), enc_csrrw(`CSR_PMPADDR1,5'd8)};    // 0x34/0x30
        dut_d.sram0.memory[7]  = {enc_csrrw(`CSR_PMPADDR2,5'd9), enc_slli(5'd9,5'd9,6'd12)}; // 0x3C/0x38 -- x9=8192=pmpaddr2
        dut_d.sram0.memory[8]  = {enc_addi(5'd11,5'd0,8), enc_addi(5'd10,5'd0,9)};          // 0x44/0x40 -- region0 byte=9, region1 byte=8
        dut_d.sram0.memory[9]  = {enc_or(5'd10,5'd10,5'd11), enc_slli(5'd11,5'd11,6'd8)};   // 0x4C/0x48
        dut_d.sram0.memory[10] = {enc_slli(5'd12,5'd12,6'd16), enc_addi(5'd12,5'd0,13)};    // 0x54/0x50 -- region2 byte=13 (TOR,X=1,R=1)
        dut_d.sram0.memory[11] = {enc_csrrw(`CSR_PMPCFG0,5'd10), enc_or(5'd10,5'd10,5'd12)}; // 0x5C/0x58
        dut_d.sram0.memory[12] = {enc_slli(5'd13,5'd13,6'd20), enc_addi(5'd13,5'd0,1028)};  // 0x64/0x60 -- x13=0x40400000
        dut_d.sram0.memory[13] = {enc_slli(5'd4,5'd4,6'd20), enc_addi(5'd4,5'd0,1028)};     // 0x6C/0x68
        dut_d.sram0.memory[14] = {enc_slli(5'd5,5'd5,6'd12), enc_addi(5'd5,5'd0,3)};        // 0x74/0x70
        dut_d.sram0.memory[15] = {enc_csrrw(`CSR_MEPC,5'd4), enc_or(5'd4,5'd4,5'd5)};       // 0x7C/0x78 -- x4=0x40403000
        dut_d.sram0.memory[16] = {enc_csrrw(`CSR_MTVEC,5'd6), enc_addi(5'd6,5'd0,256)};     // 0x84/0x80
        dut_d.sram0.memory[17] = {NOP_INSN, `INSTR_HEX_MRET};                               // 0x8C(pad)/0x88
        dut_d.sram0.memory[512 + 1] = 64'h0000_0000_0000_0801;
        dut_d.sram0.memory[1024 + 2] = 64'h0000_0000_0000_0C01;
        dut_d.sram0.memory[1536 + 3] = 64'h0000_0000_0000_10CF; // L0 entry3 (code) -> PPN=4, RWX=1
        // L0 entry0 (word 1536) left 0 -- PMP denies its own read anyway.
        dut_d.sram0.memory[2048] = {EBREAK_INSN, enc_ld(5'd30,5'd13,0)}; // 0x4004=ebreak(unreached), 0x4000=ld x30,0(x13)
        dut_d.sram0.memory[32] = {enc_csrrs(`CSR_MTVAL,5'd21), enc_csrrs(`CSR_MCAUSE,5'd20)};
        dut_d.sram0.memory[33] = {NOP_INSN, EBREAK_INSN};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "Sv39 mem walker test never halted");

        check("A: store+load round trip through translation (x30==555)",
              dut_a.core0.regfile0.gp_registers[30], 64'd555);

        check("B: AMOADD.D returns the OLD value (x9==100)", dut_b.core0.regfile0.gp_registers[9], 64'd100);
        check("B: AMOADD.D's write phase landed the NEW value at the translated PA (x30==150)",
              dut_b.core0.regfile0.gp_registers[30], 64'd150);

        check("C: store to a read-only page produces mcause==15 (store/AMO page fault)", mcause_c, 64'd15);
        check("C: mtval == the faulting VIRTUAL address", mtval_c, 64'h40404000);

        check("D: PMP-denied PTE read (mem stream) produces mcause==5 (load access fault), NOT 13",
              mcause_d, 64'd5);
        check("D: mtval == the faulting instruction's own VA (not the PTE's PA)", mtval_d, 64'h40400000);

        $display("");
        $display("core_sv39_mem_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_mem_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
