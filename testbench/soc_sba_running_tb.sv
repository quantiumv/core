// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: soc_sba_running_tb -- System Bus Access against a RUNNING hart
 *
 * Regression for the SBA "ghost request" bug fixed by design/wb_arbiter2.sv's
 * DROP_REQ_ON_RESP (see that file's own header for the full mechanism):
 * dm0's SBA master holds cyc/stb through its own ack cycle, and without the
 * fix every slave behind decoder0 re-fires on that held request. Every
 * phase below FAILS against soc.sv with arb0's DROP_REQ_ON_RESP forced to
 * 0 (confirmed by revert-and-recheck when this test was written), and
 * passes with it set.
 *
 * dm0's plain register interface is driven directly (forced dm0.i_reg_*
 * single-cycle write strobes, the same shape dm_dmi.sv produces) rather
 * than through JTAG -- testbench/jtag_dmi_e2e_tb.sv already covers the real
 * JTAG transport; this test needs SBA traffic dense enough to land while
 * the hart's own loads/stores are in flight, which bit-banged JTAG is far
 * too slow to produce.
 *
 * Phases (soc is reset between them; RAM contents survive reset, so the
 * program and result block are reloaded each time):
 *   1. SBA 64-bit WRITES to RAM (0x30000) while core0 runs a 3000-iteration
 *      `sd; ld; bne` self-check at 0x10000. Unfixed: dcache0 starts a ghost
 *      write whose ack completes core0's own next store/load -- the store
 *      is silently lost and the self-check fails.
 *   2. SBA 64-bit READS of 0x0800_0000 (RAM-decoded by decoder0, but past
 *      wb4_sram's 64MB -> refill error) while the same program runs.
 *      Unfixed: the ghost read's error is delivered to core0 as a spurious
 *      load/store access fault.
 *   3. SBA byte WRITES to the UART THR -- each must print exactly once.
 *   4. SBA byte READS of the UART RBR -- each must pop exactly one byte.
 */
module soc_sba_running_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    soc dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    localparam logic [6:0] DMI_SBCS       = 7'h38;
    localparam logic [6:0] DMI_SBADDRESS0 = 7'h39;
    localparam logic [6:0] DMI_SBDATA0    = 7'h3C;
    localparam logic [6:0] DMI_SBDATA1    = 7'h3D;

    localparam logic [31:0] UART_BASE  = 32'h0400_8000;
    localparam logic [31:0] RESULT     = 32'h0002_0000;
    localparam logic [31:0] SBA_TARGET = 32'h0003_0000;
    localparam int          ITERS      = 3000;
    localparam int          PHASE_TIMEOUT = 400000;

    logic halted = 1'b0;
    int   spurious_traps = 0;
    int   ghost_samples  = 0;
    int   cyc_n = 0;

    always @(posedge clk) begin
        cyc_n <= cyc_n + 1;
        if (rst) halted <= 1'b0;
        else if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;
    end

    /*
     * Mechanism-level monitor: dcache0 sampling cyc&&stb in CACHE_IDLE on
     * the same cycle its OWN ack_o/err_o is high is exactly the ghost
     * request this test exists to catch (a correctly-behaving master has
     * already dropped cyc by then). Counted independently of whether the
     * ghost happens to corrupt anything observable.
     */
    always @(posedge clk) if (!rst) begin
        if (dut.core0.trap_taken && !dut.core0.is_ebreak)
            spurious_traps = spurious_traps + 1;
        if (dut.cache0.dcache0.state_q == 0 && dut.cache0.dcache0.cyc_i && dut.cache0.dcache0.stb_i
                && (dut.cache0.dcache0.ack_o || dut.cache0.dcache0.err_o))
            ghost_samples = ghost_samples + 1;
    end

    // Static, not automatic: Icarus rejects `force` from an automatic
    // task's own arguments. Calls are strictly sequential, so it's safe.
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

    /*
     * The self-check program (RV64I, hand-encoded, two instructions per
     * 64-bit SRAM word, low word first):
     *   0x00 lui   s0,0x10         s0 = 0x10000 (core0's own data word)
     *   0x04 lui   s3,0x20         s3 = 0x20000 (result block)
     *   0x08 li    s1,1            i = 1
     *   0x0C lui   s2,0x1
     *   0x10 addiw s2,s2,-1096     s2 = 3000
     *   0x14 loop: sd s1,0(s0)
     *   0x18       ld t0,0(s0)
     *   0x1C       bne t0,s1,fail
     *   0x20       addi s1,s1,1
     *   0x24       blt s1,s2,loop
     *   0x28 lui   t1,0x6
     *   0x2C addiw t1,t1,13        t1 = 0x600D
     *   0x30 sd    t1,0(s3)        result[0] = 0x600D
     *   0x34 sd    s1,8(s3)        result[1] = final i
     *   0x38 ebreak
     *   0x3C fail: lui t1,0x1
     *   0x40 addiw t1,t1,-1107     t1 = 0xBAD
     *   0x44 sd    t1,0(s3)
     *   0x48 sd    s1,8(s3)
     *   0x4C sd    t0,16(s3)
     *   0x50 ebreak
     */
    task automatic load_program();
        dut.sram0.memory[0]  = {32'h000209b7, 32'h00010437};
        dut.sram0.memory[1]  = {32'h00001937, 32'h00100493};
        dut.sram0.memory[2]  = {32'h00943023, 32'hbb89091b};
        dut.sram0.memory[3]  = {32'h02929063, 32'h00043283};
        dut.sram0.memory[4]  = {32'hff24c8e3, 32'h00148493};
        dut.sram0.memory[5]  = {32'h00d3031b, 32'h00006337};
        dut.sram0.memory[6]  = {32'h0099b423, 32'h0069b023};
        dut.sram0.memory[7]  = {32'h00001337, 32'h00100073};
        dut.sram0.memory[8]  = {32'h0069b023, 32'hbad3031b};
        dut.sram0.memory[9]  = {32'h0059b823, 32'h0099b423};
        dut.sram0.memory[10] = {32'h00000013, 32'h00100073};
        for (int i = 0; i < 3; i++) dut.sram0.memory[(RESULT >> 3) + i] = 64'h0;
    endtask

    task automatic wait_halted();
        int n = 0;
        while (!halted && n < PHASE_TIMEOUT) begin
            @(posedge clk);
            n++;
        end
    endtask

    task automatic reset_soc();
        rst = 1'b1;
        repeat (5) @(posedge clk);
        spurious_traps = 0;
        ghost_samples  = 0;
        @(negedge clk);
        rst = 1'b0;
    endtask

    task automatic check_self_test(string tag);
        check({tag, ": core0 self-check passed (result flag 0x600D)"},
              dut.sram0.memory[RESULT >> 3], 64'h600D);
        check({tag, ": all iterations ran"}, dut.sram0.memory[(RESULT >> 3) + 1], 64'(ITERS));
        check({tag, ": no spurious core0 traps"}, 64'(spurious_traps), 64'd0);
        check({tag, ": dcache0 never re-sampled a request in its own ack cycle"},
              64'(ghost_samples), 64'd0);
    endtask

    int k;
    int sba_ops;
    logic [31:0] last_sba_data;

    initial begin
        force dut.dm0.i_reg_we    = 1'b0;
        force dut.dm0.i_reg_re    = 1'b0;
        force dut.dm0.i_reg_addr  = 7'h0;
        force dut.dm0.i_reg_wdata = 32'h0;
        #1; // see core_wb_tb.sv's header: run after wb4_sram's own time-0 init

        // ---- Phase 1: SBA writes to RAM while core0 runs ----
        load_program();
        reset_soc();
        dmi_write(DMI_SBCS, 32'h0006_0000);        // sbaccess=3 (64-bit)
        dmi_write(DMI_SBADDRESS0, SBA_TARGET);
        dmi_write(DMI_SBDATA1, 32'h0);
        sba_ops = 0;
        for (k = 0; k < 400 && !halted; k++) begin
            last_sba_data = 32'hA000_0000 + k;
            dmi_write(DMI_SBDATA0, last_sba_data); // triggers the write
            wait_sba_done();
            sba_ops++;
            repeat (1 + (k % 23)) @(negedge clk);
        end
        wait_halted();
        check("phase 1: hart reached ebreak", {63'b0, halted}, 64'd1);
        check("phase 1: SBA writes actually overlapped the running hart", 64'(sba_ops > 20), 64'd1);
        check_self_test("phase 1");
        check("phase 1: last SBA write landed in RAM",
              dut.sram0.memory[SBA_TARGET >> 3], {32'h0, last_sba_data});

        // ---- Phase 2: SBA reads of a RAM-decoded, out-of-range address ----
        load_program();
        reset_soc();
        sba_ops = 0;
        for (k = 0; k < 400 && !halted; k++) begin
            dmi_write(DMI_SBCS, 32'h0016_7000);    // sbreadonaddr=1, sbaccess=3, W1C sberror
            dmi_write(DMI_SBADDRESS0, 32'h0800_0000); // triggers the read
            wait_sba_done();
            sba_ops++;
            repeat (1 + (k % 23)) @(negedge clk);
        end
        wait_halted();
        check("phase 2: hart reached ebreak", {63'b0, halted}, 64'd1);
        check("phase 2: SBA reads actually overlapped the running hart", 64'(sba_ops > 20), 64'd1);
        check("phase 2: the SBA read itself reported a bus error (sberror != 0)",
              64'(dut.dm0.sberror_q != 3'd0), 64'd1);
        check_self_test("phase 2");

        // ---- Phase 3: SBA byte writes to UART THR ----
        load_program();
        reset_soc();
        dmi_write(DMI_SBCS, 32'h0000_7000);        // sbaccess=0 (8-bit), W1C sberror
        dmi_write(DMI_SBADDRESS0, UART_BASE);
        dmi_write(DMI_SBDATA0, 32'h78);            // 'x'
        wait_sba_done();
        dmi_write(DMI_SBDATA0, 32'h79);            // 'y'
        wait_sba_done();
        dmi_write(DMI_SBDATA0, 32'h7A);            // 'z'
        wait_sba_done();
        repeat (10) @(posedge clk);
        check("phase 3: each SBA THR write printed exactly once",
              {55'b0, dut.uart0.tx_history_count}, 64'd3);
        check("phase 3: tx_history[0] == 'x'", {56'b0, dut.uart0.tx_history[0]}, 64'h78);
        check("phase 3: tx_history[1] == 'y'", {56'b0, dut.uart0.tx_history[1]}, 64'h79);
        check("phase 3: tx_history[2] == 'z'", {56'b0, dut.uart0.tx_history[2]}, 64'h7A);

        // ---- Phase 4: SBA byte reads of UART RBR ----
        dut.uart0.push_byte(8'h41);                // 'A'
        dut.uart0.push_byte(8'h42);                // 'B'
        dut.uart0.push_byte(8'h43);                // 'C'
        dmi_write(DMI_SBCS, 32'h0010_7000);        // sbreadonaddr=1, sbaccess=0, W1C sberror
        dmi_write(DMI_SBADDRESS0, UART_BASE);      // triggers read #1
        wait_sba_done();
        check("phase 4: first SBA RBR read returns 'A'", {56'b0, dut.dm0.sbdata0_q[7:0]}, 64'h41);
        check("phase 4: first read popped exactly one byte", {55'b0, dut.uart0.rx_count}, 64'd2);
        dmi_write(DMI_SBADDRESS0, UART_BASE);      // triggers read #2
        wait_sba_done();
        check("phase 4: second SBA RBR read returns 'B'", {56'b0, dut.dm0.sbdata0_q[7:0]}, 64'h42);
        check("phase 4: second read popped exactly one byte", {55'b0, dut.uart0.rx_count}, 64'd1);

        $display("");
        $display("soc_sba_running_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("soc_sba_running_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
