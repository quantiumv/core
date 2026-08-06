// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: csr_file
 *
 * Standalone, drives csr_file directly -- no core involved. Needs a clock
 * (mscratch_q/mcycle_q/minstret_q are all synchronous) and a reset (all
 * three flip-flops zero on i_rst, unlike register_file.sv's gp_registers).
 */
module csr_file_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [(`CSR_ADDR_SIZE - 1):0] csr_addr;
    logic [(`WORD_SIZE - 1):0]     csr_rdata;
    logic                          csr_we;
    logic [(`WORD_SIZE - 1):0]     csr_wdata;
    logic                          instr_retired;

    csr_file dut (
        .i_clk(clk),
        .i_rst(rst),
        .i_csr_addr(csr_addr),
        .o_csr_rdata(csr_rdata),
        .i_csr_we(csr_we),
        .i_csr_wdata(csr_wdata),
        .i_instr_retired(instr_retired)
    );

    /* Local mirrors of csr_file.sv's address map -- this testbench drives
     * addresses by name, same as core.sv eventually will via imm_2, rather
     * than re-deriving them from raw hex each call site. */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MISA      = 12'h301;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MVENDORID = 12'hF11;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MARCHID   = 12'hF12;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MIMPID    = 12'hF13;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MHARTID   = 12'hF14;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MSCRATCH  = 12'h340;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MCYCLE    = 12'hB00;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MINSTRET  = 12'hB02;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_UNMAPPED  = 12'h000;

    localparam logic [(`WORD_SIZE - 1):0] MISA_VALUE = 64'h8000_0000_0000_0100;

    int pass_count = 0;
    int fail_count = 0;

    task automatic check(string name, logic [(`WORD_SIZE-1):0] actual, logic [(`WORD_SIZE-1):0] expected);
        if (actual === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    /* Read helper: drive the address, settle combinationally, sample. */
    task automatic read_csr(logic [(`CSR_ADDR_SIZE - 1):0] a, output logic [(`WORD_SIZE - 1):0] d);
        csr_addr = a;
        #1;
        d = csr_rdata;
    endtask

    /* Write helper: one synchronous write cycle, mirroring wb4_sram_tb.sv's
     * "drive on negedge, latch on posedge" convention for driving DUT
     * inputs that are sampled on the clock edge. */
    task automatic write_csr(logic [(`CSR_ADDR_SIZE - 1):0] a, logic [(`WORD_SIZE - 1):0] d);
        @(negedge clk);
        csr_addr = a; csr_wdata = d; csr_we = 1;
        @(posedge clk); #1;
        csr_we = 0;
    endtask

    logic [(`WORD_SIZE - 1):0] rdata;

    initial begin
        csr_addr = 0; csr_we = 0; csr_wdata = 0; instr_retired = 0;

        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;

        /*
         * 1. Post-reset: misa's exact fixed bit pattern, and every other
         * fixed/backed CSR reading 0.
         */
        read_csr(CSR_ADDR_MISA, rdata);
        check("post-reset misa exact bit pattern", rdata, MISA_VALUE);
        read_csr(CSR_ADDR_MVENDORID, rdata);
        check("post-reset mvendorid reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MARCHID, rdata);
        check("post-reset marchid reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MIMPID, rdata);
        check("post-reset mimpid reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MHARTID, rdata);
        check("post-reset mhartid reads 0", rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MSCRATCH, rdata);
        check("post-reset mscratch reads 0", rdata, `WORD_SIZE'(0));

        /*
         * 2. mscratch: plain read/write round trip.
         */
        write_csr(CSR_ADDR_MSCRATCH, 64'hCAFEBABE_12345678);
        read_csr(CSR_ADDR_MSCRATCH, rdata);
        check("mscratch write/read-back round trip", rdata, 64'hCAFEBABE_12345678);

        /*
         * 3. Write-to-misa (all-ones) is silently ignored -- still reads
         * the exact fixed pattern afterward.
         */
        write_csr(CSR_ADDR_MISA, 64'hFFFFFFFF_FFFFFFFF);
        read_csr(CSR_ADDR_MISA, rdata);
        check("write to misa is ignored", rdata, MISA_VALUE);

        /*
         * 4. mcycle free-runs +1 every clock edge from reset, with
         * i_csr_we/i_instr_retired both held low throughout -- proves it
         * advances unconditionally, not gated on either signal.
         */
        begin
            logic [(`WORD_SIZE - 1):0] mcycle_before, mcycle_after;
            csr_we = 0; instr_retired = 0;
            read_csr(CSR_ADDR_MCYCLE, mcycle_before);
            @(posedge clk); #1;
            read_csr(CSR_ADDR_MCYCLE, mcycle_after);
            check("mcycle free-runs +1 across one edge", mcycle_after, mcycle_before + 64'd1);
            @(posedge clk); #1;
            read_csr(CSR_ADDR_MCYCLE, mcycle_after);
            check("mcycle free-runs +1 across a second edge", mcycle_after, mcycle_before + 64'd2);
        end

        /*
         * 5. minstret stays 0 across several clock edges while
         * i_instr_retired=0, then reads back exactly K after K
         * retire-pulses -- the direct free-running-vs-gated contrast with
         * mcycle above.
         */
        instr_retired = 0;
        repeat (3) begin
            @(posedge clk); #1;
        end
        read_csr(CSR_ADDR_MINSTRET, rdata);
        check("minstret stays 0 with i_instr_retired low", rdata, `WORD_SIZE'(0));

        begin
            int unsigned k;
            k = 5;
            for (int unsigned i = 0; i < k; i++) begin
                @(negedge clk);
                instr_retired = 1;
                @(posedge clk); #1;
                instr_retired = 0;
            end
            read_csr(CSR_ADDR_MINSTRET, rdata);
            check("minstret reads back exactly K after K retire-pulses", rdata, `WORD_SIZE'(k));
        end

        /*
         * 6. Unmapped address reads 0.
         */
        read_csr(CSR_ADDR_UNMAPPED, rdata);
        check("unmapped address reads 0", rdata, `WORD_SIZE'(0));

        /*
         * 7. A write to an unmapped address doesn't corrupt mscratch --
         * regression, mirrors register_file_tb.sv's write-enable-polarity
         * regression pattern: write a known value to mscratch, then
         * attempt an unmapped write, then confirm mscratch is untouched.
         */
        write_csr(CSR_ADDR_MSCRATCH, 64'hA5A5A5A5_5A5A5A5A);
        write_csr(CSR_ADDR_UNMAPPED, 64'hFFFFFFFF_FFFFFFFF);
        read_csr(CSR_ADDR_MSCRATCH, rdata);
        check("write to unmapped address doesn't corrupt mscratch", rdata, 64'hA5A5A5A5_5A5A5A5A);

        /*
         * 8. Direct write attempts at mcycle/minstret are ignored -- both
         * counters have no write-reacting arm, so a write must not alter
         * their free-running/retirement-driven progression.
         */
        begin
            logic [(`WORD_SIZE - 1):0] mcycle_before, mcycle_after, minstret_after;
            read_csr(CSR_ADDR_MCYCLE, mcycle_before);
            write_csr(CSR_ADDR_MCYCLE, 64'hDEADDEAD_DEADDEAD);
            read_csr(CSR_ADDR_MCYCLE, mcycle_after);
            // write_csr consumed one clock edge, so mcycle free-runs by
            // exactly +1 regardless -- the check is that it is NOT the
            // written value, and matches the expected free-run count.
            check("direct write to mcycle is ignored (still free-running)", mcycle_after, mcycle_before + 64'd1);

            read_csr(CSR_ADDR_MINSTRET, rdata);
            write_csr(CSR_ADDR_MINSTRET, 64'hDEADDEAD_DEADDEAD);
            read_csr(CSR_ADDR_MINSTRET, minstret_after);
            check("direct write to minstret is ignored (i_instr_retired stayed low)", minstret_after, rdata);
        end

        $display("");
        $display("csr_file_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("csr_file_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
