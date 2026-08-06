// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: csr_file_random_tb
 *
 * Randomized property test for csr_file.sv -- separate from the existing
 * directed csr_file_tb.sv (don't touch a 16/16-passing file; this repo's
 * convention is one file per testbench concern). Duplicates that file's
 * small clk/rst/check()/read_csr/write_csr scaffold rather than sharing it,
 * per the same convention.
 *
 * Approach: a plain testbench-local shadow model (no SV classes -- three
 * shadow registers, shadow_mscratch/shadow_mcycle/shadow_minstret, updated
 * every edge with the exact same rules as the RTL). Each of NUM_ITER
 * iterations drives one randomized clock edge (address, we, wdata, and
 * instr_retired all randomized independently of each other), updates the
 * shadow model with that same edge's driven values, then combinationally
 * sweeps all 8 backed CSR addresses plus 2 unmapped addresses and checks
 * each against the shadow model / fixed constants.
 *
 * The address is drawn with an explicit bias ($urandom_range(0,9): 0-7
 * index the 8 backed addresses, 8 is a fixed unmapped probe, 9 is a fully
 * random 12-bit address) -- uniform random over 12 bits would almost never
 * hit the 8 real ones, and this core has no CSR address-decode logic
 * *other* than the case statement being tested here, so "mostly hit real
 * addresses, occasionally probe the address space at large" is the useful
 * distribution. Driving we/wdata/instr_retired independently of the
 * address and of each other is the key incremental value over the
 * directed test: it exercises simultaneous csr_we+instr_retired on
 * arbitrary addresses on the same edge, which csr_file_tb.sv never does
 * (it tests writes and retire-pulses in temporally separate sections).
 *
 * Seeding: this codebase has no existing randomization anywhere, and this
 * iverilog build's bare $urandom/$urandom_range are already confirmed
 * run-to-run deterministic unseeded (no explicit $srandom call here --
 * this iverilog build has no bare $srandom task, and adding one would not
 * compile).
 */
module csr_file_random_tb;

    localparam int NUM_ITER = 2000;

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

    /* Local mirrors of csr_file.sv's address map -- same reasoning as
     * csr_file_tb.sv's copy: this testbench drives addresses by name
     * rather than re-deriving them from raw hex at every call site. */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MISA       = 12'h301;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MVENDORID  = 12'hF11;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MARCHID    = 12'hF12;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MIMPID     = 12'hF13;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MHARTID    = 12'hF14;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MSCRATCH   = 12'h340;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MCYCLE     = 12'hB00;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MINSTRET   = 12'hB02;

    /* Two addresses guaranteed distinct from all 8 backed ones above and
     * from each other -- used both as the fixed "unmapped probe" (bias
     * value 8) and as two of the fixed addresses in every iteration's
     * invariant sweep. */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_UNMAPPED_1 = 12'h000;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_UNMAPPED_2 = 12'h7FF;

    localparam logic [(`WORD_SIZE - 1):0] MISA_VALUE = 64'h8000_0000_0000_0100;

    /* Shadow model -- plain variables, not clocked flops. Updated by hand
     * in the loop below with the same rules csr_file.sv's always_ff
     * blocks implement, using the exact values driven on that same edge. */
    logic [(`WORD_SIZE - 1):0] shadow_mscratch = `WORD_SIZE'(0);
    logic [(`WORD_SIZE - 1):0] shadow_mcycle   = `WORD_SIZE'(0);
    logic [(`WORD_SIZE - 1):0] shadow_minstret = `WORD_SIZE'(0);

    int pass_count = 0;
    int fail_count = 0;

    /* Same signature/semantics as csr_file_tb.sv's check() (===, pass/fail
     * counting), but quiet on PASS -- NUM_ITER * 10 checks would otherwise
     * flood the log with ~20000 PASS lines. Failures always print in full,
     * with the iteration number baked into the name string. */
    task automatic check(string name, logic [(`WORD_SIZE-1):0] actual, logic [(`WORD_SIZE-1):0] expected);
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    /* Read helper: drive the address, settle combinationally, sample.
     * Unlike csr_file_tb.sv's read_csr (which settles with #1), this one
     * settles with #0 -- a delta-cycle wait that lets the always_comb
     * read mux react without advancing wall-clock time. check_all_csrs()
     * below calls this 10 times per iteration; at #1 each, that sweep
     * would itself burn 10ns of simulated time against a clk period of
     * 10ns (`always #5 clk = ~clk`), letting the free-running clock tick
     * through real edges mid-sweep that the shadow model below never
     * observes -- a real bug hit while developing this file (mcycle
     * drifted ahead of shadow_mcycle within a few iterations). #0 keeps
     * the entire sweep at the same simulation timestamp, no clock edges
     * possible in between. No clock edge involved either way, so calling
     * this repeatedly mid-sweep cannot itself cause a write, regardless
     * of whatever csr_we/csr_wdata are currently holding left over from
     * the last driven edge. */
    task automatic read_csr(logic [(`CSR_ADDR_SIZE - 1):0] a, output logic [(`WORD_SIZE - 1):0] d);
        csr_addr = a;
        #0;
        d = csr_rdata;
    endtask

    /* Invariant sweep: all 8 backed CSRs plus the 2 unmapped addresses,
     * checked against the shadow model / fixed constants. Runs once per
     * iteration, after that iteration's randomized edge and shadow update. */
    task automatic check_all_csrs(int iter);
        logic [(`WORD_SIZE - 1):0] rdata;

        read_csr(CSR_ADDR_MISA, rdata);
        check($sformatf("iter %0d: misa", iter), rdata, MISA_VALUE);
        read_csr(CSR_ADDR_MVENDORID, rdata);
        check($sformatf("iter %0d: mvendorid", iter), rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MARCHID, rdata);
        check($sformatf("iter %0d: marchid", iter), rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MIMPID, rdata);
        check($sformatf("iter %0d: mimpid", iter), rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MHARTID, rdata);
        check($sformatf("iter %0d: mhartid", iter), rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_MSCRATCH, rdata);
        check($sformatf("iter %0d: mscratch", iter), rdata, shadow_mscratch);
        read_csr(CSR_ADDR_MCYCLE, rdata);
        check($sformatf("iter %0d: mcycle", iter), rdata, shadow_mcycle);
        read_csr(CSR_ADDR_MINSTRET, rdata);
        check($sformatf("iter %0d: minstret", iter), rdata, shadow_minstret);
        read_csr(CSR_ADDR_UNMAPPED_1, rdata);
        check($sformatf("iter %0d: unmapped 12'h000", iter), rdata, `WORD_SIZE'(0));
        read_csr(CSR_ADDR_UNMAPPED_2, rdata);
        check($sformatf("iter %0d: unmapped 12'h7FF", iter), rdata, `WORD_SIZE'(0));
    endtask

    initial begin
        int unsigned sel;
        logic [(`CSR_ADDR_SIZE - 1):0] addr;
        logic                          we;
        logic [(`WORD_SIZE - 1):0]     wdata;
        logic                          retired;

        csr_addr = 0; csr_we = 0; csr_wdata = 0; instr_retired = 0;

        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;

        for (int i = 0; i < NUM_ITER; i++) begin
            /* Biased address selection -- see module header. */
            sel = $urandom_range(0, 9);
            case (sel)
                0: addr = CSR_ADDR_MISA;
                1: addr = CSR_ADDR_MVENDORID;
                2: addr = CSR_ADDR_MARCHID;
                3: addr = CSR_ADDR_MIMPID;
                4: addr = CSR_ADDR_MHARTID;
                5: addr = CSR_ADDR_MSCRATCH;
                6: addr = CSR_ADDR_MCYCLE;
                7: addr = CSR_ADDR_MINSTRET;
                8: addr = CSR_ADDR_UNMAPPED_1;
                default: addr = (`CSR_ADDR_SIZE)'($urandom_range(0, 4095));
            endcase

            /* we/wdata/instr_retired randomized independently of the
             * address and of each other -- the point being to exercise
             * csr_we and instr_retired both asserted on the same edge,
             * at an arbitrary address, which csr_file_tb.sv never does. */
            we      = 1'($urandom_range(0, 1));
            wdata   = {$urandom(), $urandom()};
            retired = 1'($urandom_range(0, 1));

            /* Drive on negedge, latch on posedge -- same convention
             * csr_file_tb.sv's write_csr uses for driving DUT inputs
             * that are sampled on the clock edge. */
            @(negedge clk);
            csr_addr = addr; csr_we = we; csr_wdata = wdata; instr_retired = retired;
            @(posedge clk); #1;

            /* Shadow model update -- exact same rules as csr_file.sv's
             * three always_ff blocks, applied with this same edge's
             * driven values. */
            if (we && (addr == CSR_ADDR_MSCRATCH))
                shadow_mscratch = wdata;
            shadow_mcycle = shadow_mcycle + `WORD_SIZE'(1);
            if (retired)
                shadow_minstret = shadow_minstret + `WORD_SIZE'(1);

            check_all_csrs(i);
        end

        $display("");
        $display("csr_file_random_tb: %0d iterations, %0d checks passed, %0d checks failed",
                  NUM_ITER, pass_count, fail_count);
        if (fail_count > 0) $display("csr_file_random_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
