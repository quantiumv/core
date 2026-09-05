// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: end-to-end Debug Module access through the REAL JTAG TAP
 * and DMI transport (design/jtag_tap.sv + design/dm_dmi.sv), against a
 * real `soc` instance -- re-running Milestone 5's own dm_tb.sv
 * dut_basic scenario (haltreq -> Access Register GPR read -> Access
 * Register GPR write -> resumereq, mutated value visible after resume)
 * bit-banged through the real TAP instead of dm_tb.sv's own plain-
 * register-interface backdoor, proving the transport layer (jtag_tap.sv
 * + dm_dmi.sv's CDC bridge) adds no functional gap over that backdoor.
 *
 * Shares jtag_tap_tb.sv's own low-level tck_pulse/jtag_shift/
 * jtag_goto_shift_ir/jtag_goto_shift_dr/jtag_update_and_idle/
 * jtag_write_ir tasks (duplicated here, not included via a shared file
 * -- this project's own established convention for
 * small, testbench-local helper sets, e.g. dm_tb.sv's own DMI_* address
 * localparams duplicated from design/dm.sv rather than cross-referenced),
 * plus new DMI-specific tasks (dmi_shift/dmi_write_reg/dmi_read_reg) that
 * pack/unpack the 41-bit DMI register and implement the busy/retry poll
 * loop the RISC-V Debug Spec's own protocol requires.
 *
 * Program deliberately differs from dm_tb.sv's own dut_basic in one
 * important way: a real JTAG DMI transaction (an IR write plus a 41-bit
 * DR shift, often several of them for the busy/retry poll loop) takes
 * on the order of hundreds of simulation time units -- far longer than
 * this core takes to retire a handful of ADDIs. Timing the halt request
 * to land at an EXACT commit count (dm_tb.sv's own approach, correct
 * there since its backdoor writes land in ~1 clk cycle) doesn't work
 * here: by the time a real haltreq DMI write actually completes, the
 * core would already have run far past any specific early instruction,
 * potentially through the whole program and into its own unconfigured-
 * mtvec EBREAK trap loop. So instead of racing a precise instruction
 * count, the program spins forever at a JAL-to-self once its setup is
 * done -- haltreq is guaranteed to eventually catch the core AT that
 * spin point, no matter how long the JTAG transaction takes. Escaping
 * the spin loop after resume needs the debugger to redirect execution
 * away from it -- done here via a real Access Register CSR WRITE to
 * dpc (CSR 0x7B1, shipped in Milestone 3) BEFORE issuing resumereq, a
 * legitimate, useful capability this test gets to exercise for free.
 *
 *  0x00  addi x1,x0,10
 *  0x04  addi x2,x0,20
 *  0x08  addi x3,x0,30
 *  0x0C  jal  x0,0                spins here forever (self-jump) --
 *                                  haltreq always eventually catches
 *                                  this, dpc reads 0x0C regardless of
 *                                  which pass of the loop it landed on
 *  0x10  addi x4,x2,0             reached only via the debugger's own
 *                                  dpc redirect after resume -- uses
 *                                  x2, proving a DM-mutated x2 is
 *                                  visible to code that runs after
 *  0x14  ebreak
 */
module jtag_dmi_e2e_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic tck = 1'b0;
    logic tms = 1'b1;
    logic tdi = 1'b0;
    logic tdo;
    // Genuine 1->0->1 pulse required, not a declaration-time default --
    // see jtag_tap_tb.sv's own header/reset-block comment for why.
    logic trst_n = 1'b1;

    soc dut (
        .clk(clk), .rst(rst),
        .jtag_tck(tck), .jtag_tms(tms), .jtag_tdi(tdi), .jtag_tdo(tdo),
        .jtag_trst_n(trst_n)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    logic halted = 1'b0;
    `include "halt_wait.sv"

    // A sticky latch, armed from time 0 -- NOT a fork/wait started only
    // after the resume DMI write completes. trap_taken/is_ebreak is a
    // single-cycle pulse, and once resumed the core runs at its own
    // (fast) speed while this testbench is still busy bit-banging the
    // NEXT slow DMI transaction -- a wait() only armed after that
    // transaction finishes can miss the pulse entirely if the core
    // already reached, trapped on, and moved past the final EBREAK in
    // the meantime (this project's own established idiom for exactly
    // this class of race, e.g. core_debug_halt_tb.sv's dut_halt_ebreak).
    logic ebreak_seen = 1'b0;
    always @(posedge clk)
        if (dut.core0.trap_taken && dut.core0.is_ebreak) ebreak_seen <= 1'b1;

    localparam [4:0] IR_DMI = 5'h11;

    localparam [6:0] DMI_DATA0     = 7'h04;
    localparam [6:0] DMI_DATA1     = 7'h05;
    localparam [6:0] DMI_DMCONTROL = 7'h10;
    localparam [6:0] DMI_COMMAND   = 7'h17;

    localparam [11:0] CSR_DPC = 12'h7B1;  // Milestone 3

    task automatic tck_pulse(input logic tms_val, input logic tdi_val, output logic tdo_val);
        tdo_val = tdo;
        tms = tms_val;
        tdi = tdi_val;
        #2;
        tck = 1'b1;
        #2;
        tck = 1'b0;
        #2;
    endtask

    task automatic jtag_shift(input int width, input logic [63:0] data_in, output logic [63:0] data_out);
        logic tdo_bit;
        data_out = 64'b0;
        for (int i = 0; i < width; i++) begin
            tck_pulse((i == width - 1) ? 1'b1 : 1'b0, data_in[i], tdo_bit);
            data_out[i] = tdo_bit;
        end
    endtask

    task automatic jtag_goto_shift_ir();
        logic dummy;
        tck_pulse(1'b1, 1'b0, dummy);
        tck_pulse(1'b1, 1'b0, dummy);
        tck_pulse(1'b0, 1'b0, dummy);
        tck_pulse(1'b0, 1'b0, dummy);
    endtask

    task automatic jtag_goto_shift_dr();
        logic dummy;
        tck_pulse(1'b1, 1'b0, dummy);
        tck_pulse(1'b0, 1'b0, dummy);
        tck_pulse(1'b0, 1'b0, dummy);
    endtask

    task automatic jtag_update_and_idle();
        logic dummy;
        tck_pulse(1'b1, 1'b0, dummy);
        tck_pulse(1'b0, 1'b0, dummy);
    endtask

    task automatic jtag_write_ir(input logic [4:0] ir_val);
        logic [63:0] dummy_out;
        jtag_goto_shift_ir();
        jtag_shift(5, {59'b0, ir_val}, dummy_out);
        jtag_update_and_idle();
    endtask

    /*
     * dmi_shift: one full 41-bit DMI DR scan. Always (re-)selects
     * IR=DMI first -- redundant once already selected, but simple and
     * robust, matching how a naive real debugger driver would behave
     * too. Field layout: [40:34]=address, [33:2]=data, [1:0]=op.
     */
    task automatic dmi_shift(input logic [6:0] addr, input logic [31:0] data, input logic [1:0] op,
                              output logic [31:0] result_data, output logic [1:0] result_op);
        logic [63:0] dr_in, dr_out;
        dr_in = {23'b0, addr, data, op};
        jtag_write_ir(IR_DMI);
        jtag_goto_shift_dr();
        jtag_shift(41, dr_in, dr_out);
        jtag_update_and_idle();
        result_data = dr_out[33:2];
        result_op   = dr_out[1:0];
    endtask

    localparam int DMI_RETRY_LIMIT = 50;

    task automatic dmi_write_reg(input logic [6:0] addr, input logic [31:0] data);
        logic [31:0] rd;
        logic [1:0]  rop;
        int retries;
        dmi_shift(addr, data, 2'd2, rd, rop);  // op=2=write; this shift's own result is stale/irrelevant
        retries = 0;
        rop = 2'd3;
        while (rop == 2'd3) begin
            if (retries >= DMI_RETRY_LIMIT) begin
                $display("TIMEOUT: dmi_write_reg never left busy (addr=0x%0h)", addr);
                $finish;
            end
            dmi_shift(7'b0, 32'b0, 2'd0, rd, rop);  // op=0=nop -- safe to poll while outstanding
            retries++;
        end
    endtask

    task automatic dmi_read_reg(input logic [6:0] addr, output logic [31:0] data_out);
        logic [31:0] rd;
        logic [1:0]  rop;
        int retries;
        dmi_shift(addr, 32'b0, 2'd1, rd, rop);  // op=1=read
        retries = 0;
        rop = 2'd3;
        while (rop == 2'd3) begin
            if (retries >= DMI_RETRY_LIMIT) begin
                $display("TIMEOUT: dmi_read_reg never left busy (addr=0x%0h)", addr);
                $finish;
            end
            dmi_shift(7'b0, 32'b0, 2'd0, rd, rop);
            retries++;
        end
        data_out = rd;
    endtask

    initial begin
        #1;

        dut.sram0.memory[0] = {encode_i(32'sd20, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                                encode_i(32'sd10, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut.sram0.memory[1] = {encode_j(0, 5'd0, `OPC_JAL),
                                encode_i(32'sd30, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM)};
        dut.sram0.memory[2] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                encode_i(32'sd0, 5'd2, 3'b000, 5'd4, `OPC_OP_IMM)};

        @(posedge clk); #1;
        rst = 0;
        trst_n = 1'b0;
        repeat (3) @(posedge clk);
        trst_n = 1'b1;
        repeat (3) @(posedge clk);

        // "Activate" the DM (real-debugger hygiene, same as dm_tb.sv).
        dmi_write_reg(DMI_DMCONTROL, 32'h0000_0001);

        // Request a halt -- no precise timing needed (see the module
        // header): the program spins at the JAL-to-self (0x0C) once its
        // setup is done, well before this slow DMI transaction could
        // possibly complete, so haltreq is guaranteed to eventually
        // catch it there regardless of how long the JTAG transaction
        // itself takes.
        dmi_write_reg(DMI_DMCONTROL, 32'h8000_0001);  // haltreq=1, dmactive=1

        fork
            wait (dut.core0.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: jtag_dmi_e2e_tb never halted");
                $finish;
            end
        join_any
        disable fork;
        #1;

        check("jtag_dmi_e2e: x1 == 10, x2 == 20, x3 == 30 -- setup ran before the spin loop",
            {dut.core0.regfile0.gp_registers[1], dut.core0.regfile0.gp_registers[2],
             dut.core0.regfile0.gp_registers[3]} == {64'd10, 64'd20, 64'd30}, 1'b1);
        check("jtag_dmi_e2e: dpc == 0x0C -- caught spinning at the JAL-to-self",
            dut.core0.dpc_w, 64'h0C);

        // Access Register READ x1 (regno 0x1001), through the real TAP.
        dmi_write_reg(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b0, 16'h1001});
        begin
            logic [31:0] rd;
            dmi_read_reg(DMI_DATA0, rd);
            check("jtag_dmi_e2e: Access Register READ x1 -> data0 == 10 (via real TAP)",
                {32'b0, rd}, 64'd10);
        end

        // Access Register WRITE x2 = 99 (regno 0x1002), through the
        // real TAP.
        dmi_write_reg(DMI_DATA0, 32'd99);
        dmi_write_reg(DMI_DATA1, 32'd0);
        dmi_write_reg(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b1, 16'h1002});

        check("jtag_dmi_e2e: Access Register WRITE landed -- x2 == 99 (white-box, via real TAP)",
            dut.core0.regfile0.gp_registers[2], 64'd99);

        // Access Register CSR WRITE, redirecting dpc (CSR 0x7B1) away
        // from the JAL spin loop to 0x10 -- otherwise resuming would
        // just re-enter the same self-jump forever. A real, useful
        // debugger capability, exercised here through the same Access
        // Register path as the GPR write above (regno for a CSR is the
        // CSR address itself, in the 0x0000-0x0FFF range).
        dmi_write_reg(DMI_DATA0, 32'h0000_0010);
        dmi_write_reg(DMI_DATA1, 32'd0);
        dmi_write_reg(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b1, 4'b0, CSR_DPC});

        // Resume, through the real TAP -- execution continues from the
        // redirected dpc (0x10): addi x4,x2,0, which must see the
        // MUTATED x2 (99), proving both the GPR write and the dpc
        // redirect survived the round trip through the real transport,
        // not just a white-box peek taken while still halted.
        dmi_write_reg(DMI_DMCONTROL, 32'h4000_0001);  // resumereq=1, dmactive=1

        // Poll the sticky ebreak_seen latch (armed from time 0, see its
        // own declaration above), not a fresh wait() on trap_taken/
        // is_ebreak -- the core resumes at full speed while this
        // testbench is still finishing up the slow resumereq DMI
        // transaction, so a wait() started only now could miss the
        // single-cycle trap_taken pulse entirely.
        fork
            wait (ebreak_seen === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: jtag_dmi_e2e_tb never reached its final EBREAK after resume");
                $finish;
            end
        join_any
        disable fork;
        #1;

        check("jtag_dmi_e2e: x4 == 99 -- reached only via the debugger's dpc redirect, and sees the DM-mutated x2",
            dut.core0.regfile0.gp_registers[4], 64'd99);

        $display("");
        $display("jtag_dmi_e2e_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("jtag_dmi_e2e_tb: FAILURES PRESENT");
        $finish;
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
