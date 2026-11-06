// SPDX-License-Identifier: MIT

`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"

/*
 * csr_file_fp_tb: csr_file with FP_EN = 1, the F/D state (csr_file_tb covers the FP_EN = 0 default, where FS
 * reads 0 and the FP CSRs are unmapped). Expected values follow the rules probed on Sail
 * (verification/fpu/README.md), not csr_file.sv's own code:
 *  - mstatus.FS stores all four values, through mstatus and sstatus; SD (bit 63) reads FS == Dirty, in both views;
 *  - fflags/frm/fcsr: fcsr = {frm, fflags}, frm keeps any 3-bit value, the other bits read 0;
 *  - FS becomes Dirty (FS != Off only) on an FP register write, on an accrual that changes fflags (not one that
 *    raises an already-set flag), and on any CSR write to fflags/frm/fcsr, whatever the value;
 *  - accrual ORs into fflags; traps and xRET leave FS alone; misa adds the F and D letters.
 */
module csr_file_fp_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [(`CSR_ADDR_SIZE - 1):0] csr_addr = 0;
    logic [(`WORD_SIZE - 1):0]     csr_rdata;
    logic                          csr_we = 0;
    logic [(`WORD_SIZE - 1):0]     csr_wdata = 0;
    logic                          trap_taken = 0, mret_taken = 0;
    logic                          frd_we = 0;
    logic [4:0]                    accrue = 0;
    logic [1:0]                    fs_w;
    logic [2:0]                    frm_w;
    logic [4:0]                    fflags_w;

    /* verilator lint_off PINMISSING */
    csr_file #(.FP_EN(1'b1)) dut (
        .i_clk(clk), .i_rst(rst),
        .i_csr_addr(csr_addr), .o_csr_rdata(csr_rdata), .i_csr_we(csr_we), .i_csr_wdata(csr_wdata),
        .i_instr_retired(1'b0), .i_current_priv(2'b11),
        .i_trap_taken(trap_taken), .i_trap_cause(64'd2), .i_trap_val(64'd0), .i_trap_pc(64'h100),
        .i_trap_to_s(1'b0), .i_mret_taken(mret_taken), .i_sret_taken(1'b0),
        .i_fp_frd_we(frd_we), .i_fp_accrue(accrue),
        .o_mstatus_fs(fs_w), .o_frm(frm_w), .o_fflags(fflags_w)
    );
    /* verilator lint_on PINMISSING */

    localparam logic [11:0] FFLAGS = 12'h001, FRM = 12'h002, FCSR = 12'h003;
    localparam logic [11:0] SSTATUS = 12'h100, MSTATUS = 12'h300, MISA = 12'h301;
    localparam logic [63:0] FS_MASK = 64'h6000, SD = 64'h8000_0000_0000_0000;
    localparam logic [63:0] UXL = 64'h2_0000_0000, SXL = 64'h8_0000_0000;

    int pass_count = 0;
    int fail_count = 0;

    task automatic check(string name, logic [63:0] actual, logic [63:0] expected);
        if (actual === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    task automatic rd(logic [11:0] a, output logic [63:0] d);
        csr_addr = a;
        #1;
        d = csr_rdata;
    endtask

    task automatic wr(logic [11:0] a, logic [63:0] d);
        @(negedge clk);
        csr_addr = a; csr_wdata = d; csr_we = 1;
        @(posedge clk); #1;
        csr_we = 0;
    endtask

    // one cycle of the commit side channels
    task automatic commit_fp(logic we, logic [4:0] flags);
        @(negedge clk);
        frd_we = we; accrue = flags;
        @(posedge clk); #1;
        frd_we = 0; accrue = 0;
    endtask

    task automatic set_fs(logic [1:0] fs);
        wr(MSTATUS, 64'(fs) << 13);
    endtask

    logic [63:0] d;

    initial begin
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;

        // 1. reset
        rd(MSTATUS, d);  check("reset: mstatus (FS Off, no SD)", d, UXL | SXL);
        rd(FCSR, d);     check("reset: fcsr", d, 0);
        check("reset: o_mstatus_fs", fs_w, 0);
        rd(MISA, d);     check("misa has A C D F I M S U", d, 64'h8000_0000_0014_112D);

        // 2. FS: all four values, through mstatus and sstatus; SD in both views
        for (int fs = 0; fs < 4; fs++) begin
            set_fs(fs[1:0]);
            rd(MSTATUS, d);
            check($sformatf("mstatus.FS = %0d", fs), d, UXL | SXL | (64'(fs) << 13) | (fs == 3 ? SD : 0));
            rd(SSTATUS, d);
            check($sformatf("sstatus view with FS = %0d", fs), d, UXL | (64'(fs) << 13) | (fs == 3 ? SD : 0));
            check($sformatf("o_mstatus_fs = %0d", fs), fs_w, fs);
        end
        set_fs(0);
        wr(SSTATUS, FS_MASK);
        rd(MSTATUS, d);  check("FS written through sstatus", d & (FS_MASK | SD), FS_MASK | SD);
        wr(MSTATUS, SD);
        rd(MSTATUS, d);  check("SD is not writable (a write of SD alone leaves FS Off)", d & (FS_MASK | SD), 0);

        // 3. fflags/frm/fcsr (FS Initial: Dirty does not change what they hold)
        set_fs(1);
        wr(FCSR, '1);
        rd(FCSR, d);     check("csrw fcsr, -1: fcsr", d, 64'hFF);
        rd(FRM, d);      check("csrw fcsr, -1: frm", d, 7);
        rd(FFLAGS, d);   check("csrw fcsr, -1: fflags", d, 64'h1F);
        check("o_frm / o_fflags", {frm_w, fflags_w}, 8'hFF);
        wr(FCSR, 0);
        wr(FRM, '1);
        rd(FRM, d);      check("csrw frm, -1", d, 7);
        rd(FFLAGS, d);   check("csrw frm leaves fflags", d, 0);
        wr(FFLAGS, '1);
        rd(FFLAGS, d);   check("csrw fflags, -1", d, 64'h1F);
        rd(FCSR, d);     check("fcsr = {frm, fflags}", d, 64'hFF);
        wr(FCSR, 64'h45);
        rd(FCSR, d);     check("fcsr write splits into frm 2 / fflags 5", {frm_w, fflags_w, d[7:0]}, {3'd2, 5'd5, 8'h45});

        // 4. accrual
        wr(FCSR, 64'h01);
        commit_fp(0, 5'h04);
        rd(FFLAGS, d);   check("accrual ORs into fflags", d, 64'h05);
        commit_fp(0, 5'h00);
        rd(FFLAGS, d);   check("no flags, no change", d, 64'h05);

        // 5. Dirty (FS Clean before each case)
        set_fs(2); commit_fp(1, 0);
        check("Dirty: FP register write", fs_w, 3);
        wr(FCSR, 64'h10); set_fs(2); commit_fp(0, 5'h10);
        check("not Dirty: an already-set flag raised again", fs_w, 2);
        rd(FFLAGS, d);   check("  ... fflags unchanged", d, 64'h10);
        wr(FCSR, 64'h00); set_fs(2); commit_fp(0, 5'h10);
        check("Dirty: a new flag", fs_w, 3);
        wr(FCSR, 64'h00); set_fs(2); wr(FFLAGS, 0);
        check("Dirty: csrw fflags with the value it holds", fs_w, 3);
        set_fs(2); wr(FRM, 0);
        check("Dirty: csrw frm", fs_w, 3);
        set_fs(2); wr(FCSR, 0);
        check("Dirty: csrw fcsr", fs_w, 3);
        set_fs(2); rd(FCSR, d); @(posedge clk); #1;
        check("not Dirty: a read", fs_w, 2);
        set_fs(1); commit_fp(1, 0);
        check("Dirty from Initial", fs_w, 3);
        set_fs(0); commit_fp(1, 5'h1F);
        check("FS Off: an FP register write does not turn it on", fs_w, 0);
        rd(FFLAGS, d);   check("FS Off: accrual still lands (commit never sends one while Off)", d, 64'h1F);
        set_fs(0); wr(FCSR, 64'h20);
        check("FS Off: a (Debug Module) fcsr write does not turn it on", fs_w, 0);
        rd(FCSR, d);     check("  ... but the write lands", d, 64'h20);

        // 6. traps and xRET leave FS alone
        set_fs(3);
        @(negedge clk); trap_taken = 1; @(posedge clk); #1; trap_taken = 0;
        check("a trap leaves FS", fs_w, 3);
        @(negedge clk); mret_taken = 1; @(posedge clk); #1; mret_taken = 0;
        check("mret leaves FS", fs_w, 3);

        $display("");
        $display("csr_file_fp_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("csr_file_fp_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
