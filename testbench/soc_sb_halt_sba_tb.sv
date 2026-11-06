// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: soc_sb_halt_sba_tb -- a halted hart's System Bus Access sees every store that retired before the halt
 *
 * With the store buffer a plain store to RAM retires before it reaches the bus, so the Debug Module's SBA, which
 * reads memory behind the core's back, could read a stale word of a store the hart has already retired. The core
 * therefore reports Debug Mode (o_debug_mode, which the Debug Module takes as "halted") only once the buffer has
 * drained. This test halts the hart at a different instant on each run, while it is storing a run of
 * consecutive dwords (more stores than the buffer holds), and reads every dword back over SBA once dmstatus says
 * halted: the first n, where n is the number of stores retired before dpc, must hold their values and the rest must be untouched.
 * It fails if o_debug_mode is raised while the buffer still holds a retired store.
 *
 * The program (RV64I, hand-encoded, two instructions per 64-bit SRAM word, low word first):
 *   0x00 lui  s0,0x30        s0 = 0x30000
 *   0x04 li   s1,0
 *   0x08 addi s1,s1,1 ; sd s1,0(s0)  ... sixteen pairs, store k writes k+1 to dword k
 *   0x88 j    .
 */
module soc_sb_halt_sba_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    soc dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    localparam logic [6:0] DMI_DMCONTROL  = 7'h10;
    localparam logic [6:0] DMI_SBCS       = 7'h38;
    localparam logic [6:0] DMI_SBADDRESS0 = 7'h39;
    localparam logic [31:0] AREA          = 32'h0003_0000;
    localparam logic [63:0] SENTINEL      = 64'hAAAA_AAAA_AAAA_AAAA;
    localparam int          STORES        = 16;
    localparam int          MAX_DELAY     = 90;

    // Static, not automatic: Icarus rejects `force` from an automatic task's own arguments.
    task dmi_write(input logic [6:0] a, input logic [31:0] d);
        @(negedge clk);
        force dut.dm0.i_reg_addr  = a;
        force dut.dm0.i_reg_wdata = d;
        force dut.dm0.i_reg_we    = 1'b1;
        @(negedge clk);
        force dut.dm0.i_reg_we    = 1'b0;
    endtask

    task automatic wait_sba_done();
        int n = 0;
        while (dut.dm0.sba_busy_q && n < 1000) begin
            @(negedge clk);
            n++;
        end
    endtask

    task automatic load_program();
        dut.sram0.memory[0] = {32'h00000493, 32'h00030437};
        dut.sram0.memory[1] = {32'h00943023, 32'h00148493};
        dut.sram0.memory[2] = {32'h00943423, 32'h00148493};
        dut.sram0.memory[3] = {32'h00943823, 32'h00148493};
        dut.sram0.memory[4] = {32'h00943c23, 32'h00148493};
        dut.sram0.memory[5] = {32'h02943023, 32'h00148493};
        dut.sram0.memory[6] = {32'h02943423, 32'h00148493};
        dut.sram0.memory[7] = {32'h02943823, 32'h00148493};
        dut.sram0.memory[8] = {32'h02943c23, 32'h00148493};
        dut.sram0.memory[9] = {32'h04943023, 32'h00148493};
        dut.sram0.memory[10] = {32'h04943423, 32'h00148493};
        dut.sram0.memory[11] = {32'h04943823, 32'h00148493};
        dut.sram0.memory[12] = {32'h04943c23, 32'h00148493};
        dut.sram0.memory[13] = {32'h06943023, 32'h00148493};
        dut.sram0.memory[14] = {32'h06943423, 32'h00148493};
        dut.sram0.memory[15] = {32'h06943823, 32'h00148493};
        dut.sram0.memory[16] = {32'h06943c23, 32'h00148493};
        dut.sram0.memory[17] = {32'h00000013, 32'h0000006f};
        for (int i = 0; i < STORES; i++) dut.sram0.memory[(AREA >> 3) + i] = SENTINEL;
    endtask

    task automatic reset_soc();
        rst = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
    endtask

    int          delay, n, waited, retired_stores, runs_with_pending;
    logic [63:0] dpc, got;
    logic        saw_pending;

    // the property itself, every cycle: Debug Mode is not reported while a retired store is still in the buffer
    int          early_halts = 0;
    always @(posedge clk) if (!rst && dut.debug_mode && !dut.core0.sb_empty) early_halts = early_halts + 1;

    initial begin
        force dut.dm0.i_reg_we    = 1'b0;
        force dut.dm0.i_reg_re    = 1'b0;
        force dut.dm0.i_reg_addr  = 7'h0;
        force dut.dm0.i_reg_wdata = 32'h0;
        #1; // run after wb4_sram's own time-0 init
        runs_with_pending = 0;

        for (delay = 0; delay <= MAX_DELAY; delay++) begin
            load_program();
            reset_soc();
            repeat (delay) @(posedge clk);
            dmi_write(DMI_DMCONTROL, 32'h8000_0001);          // haltreq, dmactive
            waited = 0;
            saw_pending = 1'b0;
            while (!dut.debug_mode && waited < 3000) begin
                @(posedge clk);
                if (dut.core0.in_debug_mode && !dut.core0.sb_empty) saw_pending = 1'b1;   // halted but not yet visible
                waited++;
            end
            check($sformatf("delay %0d: the hart halts", delay), {63'b0, dut.debug_mode}, 64'd1);
            if (saw_pending) runs_with_pending++;
            dmi_write(DMI_DMCONTROL, 32'h0000_0001);          // drop haltreq; the hart stays halted
            dpc = dut.core0.csr_file0.dpc_q;
            retired_stores = (dpc < 64'h8) ? 0 : ((dpc >= 64'h88) ? STORES : int'((dpc - 64'h8) >> 3));

            dmi_write(DMI_SBCS, 32'h0016_7000);               // sbreadonaddr, sbaccess=3 (64-bit), W1C sberror
            for (n = 0; n < STORES; n++) begin
                dmi_write(DMI_SBADDRESS0, AREA + 32'(8 * n)); // triggers the read
                wait_sba_done();
                got = {dut.dm0.sbdata1_q, dut.dm0.sbdata0_q};
                check($sformatf("delay %0d dword %0d (dpc %0h, %0d stores retired)", delay, n, dpc, retired_stores), got,
                      (n < retired_stores) ? 64'(n + 1) : SENTINEL);
            end
        end

        check("Debug Mode is never reported with a store still in the buffer", 64'(early_halts), 64'd0);
        check("some run halted with the buffer still draining (the test reaches the case it is for)",
              64'(runs_with_pending > 0), 64'd1);
        $display("soc_sb_halt_sba_tb: %0d of %0d runs had the buffer draining when the hart halted", runs_with_pending, MAX_DELAY + 1);
        $display("");
        $display("soc_sb_halt_sba_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("soc_sb_halt_sba_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
