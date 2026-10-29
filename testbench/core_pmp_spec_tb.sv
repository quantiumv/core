// SPDX-License-Identifier: MIT
/* ------------------------------------------------------------------------- */
/*
 * core_pmp_spec_tb -- errata E4-E8 on the running core (either build), through firmware/pmp_spec_test.s (see its
 * header for what each group checks). The program stores (actual, expected) pairs at RES + 8 + 16 * i and their
 * number at RES; this bench compares them. It drives i_mtip while the word at MAGIC is 1 and i_seip while it is
 * 2 (the program's two vectored-interrupt checks).
 *
 * Run from design/ (the hex is ../firmware/pmp_spec_test.hex; `make -C firmware pmp_spec_test` builds it).
 */
/* ------------------------------------------------------------------------- */
module core_pmp_spec_tb;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    localparam int RES = 32'h6000, MAGIC = 32'h6F80, N_CHECKS = 38;
    // the check names, in the program's order
    function automatic string name_of(input int i);
        case (i)
            0: return "E7 pmpcfg1 illegal";
            1: return "E7 pmpcfg2 no trap";
            2: return "E7 pmpcfg2 reads 0";
            3: return "E7 pmpaddr16 illegal";
            4: return "E7 pmpaddr15 no trap";
            5: return "E7 pmpaddr15 reads 0";
            6: return "E7 pmpcfg14 write illegal";
            7: return "E4 mtvec MODE 3 keeps 0";
            8: return "E4 mtvec MODE 1";
            9: return "E4 mtvec MODE 2 keeps 1";
            10: return "E4 stvec MODE 3 keeps 0";
            11: return "E4 stvec MODE 1";
            12: return "E4 stvec MODE 2 keeps 1";
            13: return "E5 sd partly in NA4: cause 7";
            14: return "E5 sd partly in NA4: mtval";
            15: return "E5 ld partly in NA4: cause 5";
            16: return "E5 sw inside / sd outside: no trap";
            17: return "E6 32-bit at dword+2: cause 1";
            18: return "E6 32-bit at dword+2: mepc";
            19: return "E6 32-bit at dword+2: mtval pc+2";
            20: return "E6 32-bit at dword+6: cause 1";
            21: return "E6 32-bit at dword+6: mepc";
            22: return "E6 32-bit at dword+6: mtval pc+2";
            23: return "E6 16-bit below the word runs: cause 1";
            24: return "E6 16-bit below: mepc = word";
            25: return "E6 16-bit below: mtval = word";
            26: return "E6 32-bit below the word runs: cause 1";
            27: return "E6 32-bit below: mepc = word";
            28: return "E4 M vectored MTI entry ran";
            29: return "E4 M vectored: nothing at entry 0";
            30: return "E4 S vectored SEI entry ran";
            31: return "E4 S vectored: back with ecall";
            32: return "E8 mcounteren all ones: 0x7";
            33: return "E8 scounteren all ones: 0x7";
            34: return "E8 mcounteren bits 63:3: 0";
            35: return "E8 scounteren bits 63:3: 0";
            36: return "E8 mcounteren csrs";
            37: return "E8 scounteren csrc";
            default: return "?";
        endcase
    endfunction

    logic mtip, seip;
    /* verilator lint_off PINCONNECTEMPTY */
    core_wb4_sram_harness #(.NUM_WORDS(4096)) dut (.clk(clk), .rst(rst), .i_mtip(mtip), .i_seip(seip), .o_debug_mode());
    /* verilator lint_on PINCONNECTEMPTY */
    assign mtip = (dut.sram0.memory[MAGIC / 8] == 64'd1);
    assign seip = (dut.sram0.memory[MAGIC / 8] == 64'd2);

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    logic halted = 1'b0;
    always @(posedge clk) if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"
    // +TRACE_PC: the pc every 5,000 cycles (where a core that never reaches the EBREAK spins)
    int cyc = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if ($test$plusargs("TRACE_PC") && cyc % 5000 == 0)
            $display("cycle %0d: pc %h priv %0d mcause %h", cyc, dut.core0.pc, dut.core0.current_priv,
                     dut.core0.csr_file0.mcause_q);
    end
    // +TRACE_TRAP: every trap and interrupt entry (mcause, mepc, mtval at the next cycle)
    logic trap_d = 1'b0;
    always @(posedge clk) begin
        trap_d <= dut.core0.trap_taken || dut.core0.interrupt_taken;
        if ($test$plusargs("TRACE_TRAP") && trap_d)
            $display("cycle %0d: trap mcause %h mepc %h mtval %h scause %h sepc %h", cyc, dut.core0.csr_file0.mcause_q,
                     dut.core0.csr_file0.mepc_q, dut.core0.csr_file0.mtval_q, dut.core0.csr_file0.scause_q,
                     dut.core0.csr_file0.sepc_q);
    end

    initial begin
        #1; // after wb4_sram's own time-0 load of crt0.hex
        for (int i = 0; i < 4096; i++) dut.sram0.memory[i] = 64'b0;
        $readmemh("../firmware/pmp_spec_test.hex", dut.sram0.memory);
        @(posedge clk); #1;
        rst = 0;
        wait_halted_or_timeout(200000, "EBREAK never came -- is firmware/pmp_spec_test.hex built?");
        repeat (20) @(posedge clk);   // posted stores reach the SRAM
        check("number of checks the program made", dut.sram0.memory[RES / 8], 64'(N_CHECKS));
        for (int i = 0; i < N_CHECKS; i++)
            check($sformatf("%0d %s", i + 1, name_of(i)), dut.sram0.memory[(RES + 8 + 16 * i) / 8],
                  dut.sram0.memory[(RES + 16 + 16 * i) / 8]);
        $display("");
        $display("core_pmp_spec_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_pmp_spec_tb: FAILURES PRESENT");
        $finish;
    end
endmodule
