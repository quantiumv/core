// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: register_file
 *
 * Needs a clock (writes are synchronous) but no reset port -- there isn't
 * one on this module by design, x0 is forced to 0 by the read mux instead
 * of by a reset sequence (see the first test below).
 */
module register_file_tb;

    logic clk = 0;
    always #5 clk = ~clk;

    logic [(`L2_REG_FILE_SIZE - 1):0] read_A_sel, read_B_sel;
    logic [(`WORD_SIZE - 1):0]        read_A_data, read_B_data;
    logic                              load_gpr;
    logic [(`L2_REG_FILE_SIZE - 1):0] load_gpr_sel;
    logic [(`WORD_SIZE - 1):0]        load_gpr_data;

    register_file dut (
        .i_clk(clk),
        .i_read_gpr_A_sel(read_A_sel), .o_read_gpr_A_data(read_A_data),
        .i_read_gpr_B_sel(read_B_sel), .o_read_gpr_B_data(read_B_data),
        .i_load_gpr(load_gpr), .i_load_gpr_sel(load_gpr_sel), .i_load_gpr_data(load_gpr_data)
    );

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

    initial begin
        load_gpr = 0; load_gpr_sel = 0; load_gpr_data = 0;
        read_A_sel = 0; read_B_sel = 0;

        /*
         * x0 reads 0 with no clock edge having occurred at all yet -- this
         * specifically proves the read mux forces it (combinational),
         * distinct from "it happens to read 0 because we reset/wrote it".
         */
        #1;
        check("x0 reads 0 before any clock edge", read_A_data, 64'd0);

        /*
         * Basic write/read-back: write x5, then read it on port A.
         */
        @(negedge clk);
        load_gpr = 1; load_gpr_sel = 5; load_gpr_data = 64'hDEADBEEF_00000005;
        @(posedge clk); #1;
        load_gpr = 0;
        read_A_sel = 5;
        #1;
        check("write x5 then read back on port A", read_A_data, 64'hDEADBEEF_00000005);

        /*
         * Write-enable LOW must NOT write -- direct regression for the
         * inverted-polarity bug, where write-enable low used to be exactly
         * the condition that DID write. Attempt to overwrite x6 with the
         * enable held low; x6 must stay at its (uninitialized-but-never-
         * written) state, which we prove indirectly by writing a KNOWN
         * value with the enable low, then writing a DIFFERENT known value
         * with the enable high, and confirming only the second one stuck.
         */
        @(negedge clk);
        load_gpr = 0; load_gpr_sel = 6; load_gpr_data = 64'hBAD0BAD0_BAD0BAD0; // enable LOW: must not write
        @(posedge clk); #1;
        @(negedge clk);
        load_gpr = 1; load_gpr_sel = 6; load_gpr_data = 64'h6000600060006000; // enable HIGH: must write
        @(posedge clk); #1;
        load_gpr = 0;
        read_A_sel = 6;
        #1;
        check("write-enable low did not write (polarity regression)", read_A_data, 64'h6000600060006000);

        /*
         * Attempted write to x0 must be a no-op -- x0 always reads 0
         * afterward regardless.
         */
        @(negedge clk);
        load_gpr = 1; load_gpr_sel = 0; load_gpr_data = 64'hFFFFFFFF_FFFFFFFF;
        @(posedge clk); #1;
        load_gpr = 0;
        read_A_sel = 0;
        #1;
        check("write to x0 is a no-op", read_A_data, 64'd0);

        /*
         * Dual-port simultaneous read: x5 and x6 (both written above) read
         * out correctly and independently on the same cycle, from the two
         * separate read ports.
         */
        read_A_sel = 5; read_B_sel = 6;
        #1;
        check("dual-port read, port A (x5)", read_A_data, 64'hDEADBEEF_00000005);
        check("dual-port read, port B (x6)", read_B_data, 64'h6000600060006000);

        $display("");
        $display("register_file_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("register_file_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
