// SPDX-License-Identifier: MIT
/* ------------------------------------------------------------------------- */
/*
 * core_zicntr_tb -- Zicntr on the running core (either build, built with QV_ZICNTR_EN), through
 * firmware/zicntr_test.s (see its header): cycle, time and instret at every privilege under the counter enables.
 * The program stores (actual, expected) pairs at RES + 8 + 16 * i and their number at RES; this bench compares
 * them. It drives i_time with the constant the program expects to read.
 *
 * Run from design/ (the hex is ../firmware/zicntr_test.hex; `make -C firmware zicntr_test` builds it).
 */
/* ------------------------------------------------------------------------- */
module core_zicntr_tb;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    localparam int RES = 32'h6000, N_CHECKS = 41;
    localparam logic [63:0] TIME = 64'h0123_4567_89AB_CDEF;
    // the check names, in the program's order
    function automatic string name_of(input int i);
        case (i)
            0: return "M cycle no trap";
            1: return "M time no trap";
            2: return "M instret no trap";
            3: return "M time is i_time";
            4: return "M instret: 6 instructions later, 7 more";
            5: return "M instret is minstret";
            6: return "M cycle is mcycle, a few cycles on";
            7: return "M write of time: one trap";
            8: return "M write of time: illegal instruction";
            9: return "S 0/0 cycle traps";
            10: return "S 0/0 time traps";
            11: return "S 0/0 instret traps";
            12: return "S 0/0: illegal instruction";
            13: return "S 0/0: mtval is the instruction";
            14: return "S 7/0 cycle";
            15: return "S 7/0 time";
            16: return "S 7/0 instret";
            17: return "S TM only: cycle traps";
            18: return "S TM only: time";
            19: return "S TM only: instret traps";
            20: return "U 7/0 cycle traps";
            21: return "U 7/0 time traps";
            22: return "U 7/0 instret traps";
            23: return "U 7/7 cycle";
            24: return "U 7/7 time";
            25: return "U 7/7 instret";
            26: return "U 5/3 cycle";
            27: return "U 5/3 time traps";
            28: return "U 5/3 instret traps";
            29: return "U 0/7 cycle traps";
            30: return "U 0/7 time traps";
            31: return "U 0/7 instret traps";
            32: return "priv 2 7/0 cycle traps";
            33: return "priv 2 7/0 time traps";
            34: return "priv 2 7/0 instret traps";
            35: return "priv 2 7/7 cycle";
            36: return "priv 2 7/7 time";
            37: return "priv 2 7/7 instret";
            38: return "priv 2 sets scounteren, then cycle";
            39: return "priv 2 sets scounteren, then time";
            40: return "priv 2 sets scounteren, then instret";
            default: return "?";
        endcase
    endfunction

    core_wb4_sram_harness dut (.clk(clk), .rst(rst), .i_time(TIME), .o_debug_mode());

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    logic halted = 1'b0;
    always @(posedge clk) if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"

    initial begin
        #1; // after wb4_sram's own time-0 load of crt0.hex
        for (int i = 0; i < 4096; i++) dut.sram0.memory[i] = 64'b0;
        $readmemh("../firmware/zicntr_test.hex", dut.sram0.memory);
        @(posedge clk); #1;
        rst = 0;
        wait_halted_or_timeout(200000, "EBREAK never came -- is firmware/zicntr_test.hex built?");
        repeat (20) @(posedge clk);   // posted stores reach the SRAM
        check("number of checks the program made", dut.sram0.memory[RES / 8], 64'(N_CHECKS));
        for (int i = 0; i < N_CHECKS; i++)
            check($sformatf("%0d %s", i + 1, name_of(i)), dut.sram0.memory[(RES + 8 + 16 * i) / 8],
                  dut.sram0.memory[(RES + 16 + 16 * i) / 8]);
        $display("");
        $display("core_zicntr_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_zicntr_tb: FAILURES PRESENT");
        $finish;
    end
endmodule
