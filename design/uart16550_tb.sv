// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: uart16550
 *
 * Retires design/uart_tx_tb.sv/design/uart_rx_tb.sv (both ported here
 * verbatim, at the new packed-byte-lane offsets) and adds new coverage
 * for every genuinely new piece of real 16550 behavior this milestone
 * introduces: DLAB round-trip, IER-gates-RDA, the full IIR priority
 * encode, the THRE one-shot's full cycle, OE, MCR's reserved bits, and
 * LCR's full 8-bit fidelity. Drives the Wishbone port directly, exactly
 * like every sibling peripheral testbench.
 *
 * Register access convention: every register lives at a fixed byte lane
 * of ONE 64-bit dword (see design/uart16550.sv's own header) -- addr_i
 * is never even driven meaningfully here (left at 0 throughout), and
 * sel_i alone selects the register. dat_o always carries the FULL
 * register-file snapshot regardless of which lane was actually
 * requested, so every check below masks out just the byte lane(s) it
 * cares about, never comparing the whole 64-bit dat_o the way a single-
 * register peripheral's testbench (e.g. design/clint_tb.sv) safely can.
 */
module uart16550_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        ack, err, cyc, stb, we;
    logic        irq;

    uart16550 dut (
        .clk(clk), .rst(rst),
        .addr_i(addr), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel),
        .ack_o(ack), .err_o(err), .cyc_i(cyc), .stb_i(stb), .we_i(we),
        .o_irq(irq)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    `include "wb_driver.sv"

    // Byte-lane select masks -- one bit per real register (see header).
    localparam logic [7:0] SEL0 = 8'h01; // RBR/THR (or DLL if DLAB=1)
    localparam logic [7:0] SEL1 = 8'h02; // IER     (or DLM if DLAB=1)
    localparam logic [7:0] SEL2 = 8'h04; // IIR/FCR
    localparam logic [7:0] SEL3 = 8'h08; // LCR
    localparam logic [7:0] SEL4 = 8'h10; // MCR
    localparam logic [7:0] SEL5 = 8'h20; // LSR
    localparam logic [7:0] SEL6 = 8'h40; // MSR
    localparam logic [7:0] SEL7 = 8'h80; // SCR

    initial begin
        cyc = 0; stb = 0; we = 0; addr = 0; dat_i = 0; sel = 8'h00;
        @(posedge clk); #1;
        rst = 0;

        /*
         * -- 1. TX capture (ported from design/uart_tx_tb.sv verbatim) --
         * Console output ("Hi" appearing literally in the run's stdout)
         * is a visual sanity check, not what's asserted on.
         */
        wb_cycle(32'h0, 64'h48, SEL0, 1'b1); // 'H'
        wb_cycle(32'h0, 64'h69, SEL0, 1'b1); // 'i'
        check("two characters captured", {55'b0, dut.tx_history_count}, 64'd2);
        check("history[0] == 'H'", {56'b0, dut.tx_history[0]}, 64'h48);
        check("history[1] == 'i'", {56'b0, dut.tx_history[1]}, 64'h69);

        wb_cycle(32'h0, 64'hFF, 8'h00, 1'b1); // sel[0]=0 -- must not capture
        check("write without sel[0] is ignored", {55'b0, dut.tx_history_count}, 64'd2);

        wb_cycle(32'h0, 64'h0, SEL0, 1'b0);
        check("RBR reads 0 when queue is empty", dat_o[7:0], 64'h0);

        /*
         * -- 2. RX pop / FIFO ordering / overflow-at-257 / OE --
         * (ported from design/uart_rx_tb.sv, at the new RBR/LSR offsets;
         * IER bit 0 is still 0 here, so o_irq is deliberately not
         * checked in this section -- see section 5 for IER-gates-RDA.)
         */
        dut.push_byte(8'h41); // 'A'
        dut.push_byte(8'h42); // 'B'
        dut.push_byte(8'h43); // 'C'

        wb_cycle(32'h0, 64'h0, SEL5, 1'b0);
        check("LSR.DR set after push", dat_o[40], 64'd1);

        wb_cycle(32'h0, 64'h0, SEL0, 1'b0);
        check("RBR pop 1 == 'A'", dat_o[7:0], 64'h41);
        wb_cycle(32'h0, 64'h0, SEL0, 1'b0);
        check("RBR pop 2 == 'B'", dat_o[7:0], 64'h42);
        wb_cycle(32'h0, 64'h0, SEL0, 1'b0);
        check("RBR pop 3 == 'C'", dat_o[7:0], 64'h43);

        wb_cycle(32'h0, 64'h0, SEL5, 1'b0);
        check("LSR.DR clear after drain", dat_o[40], 64'd0);

        // A read whose sel_i doesn't include lane 0 must not pop.
        dut.push_byte(8'hAA);
        wb_cycle(32'h0, 64'h0, SEL1, 1'b0); // probe a different lane
        check("read without sel[0] doesn't pop the queue", {55'b0, dut.rx_count}, 64'd1);
        wb_cycle(32'h0, 64'h0, SEL0, 1'b0);
        check("byte survives the lane-mismatched probe intact", dat_o[7:0], 64'hAA);

        // FIFO overflow at 257 bytes -- also exercises OE (new this
        // milestone): push_byte's own silent-drop-on-overflow now also
        // sets LSR's OE bit.
        for (int i = 0; i < 257; i++) begin
            dut.push_byte(i[7:0]);
        end
        check("queue caps at 256 entries, 257th byte silently dropped",
            {55'b0, dut.rx_count}, 64'd256);

        wb_cycle(32'h0, 64'h0, SEL5, 1'b0);
        check("LSR.OE set after overflow", dat_o[41], 64'd1);
        wb_cycle(32'h0, 64'h0, SEL5, 1'b0);
        check("LSR.OE clears on an LSR read", dat_o[41], 64'd0);

        quiet_on_pass = 1'b1;
        for (int i = 0; i < 256; i++) begin
            wb_cycle(32'h0, 64'h0, SEL0, 1'b0);
            check($sformatf("overflow drain byte %0d in FIFO order", i), dat_o[7:0], {56'b0, i[7:0]});
        end
        quiet_on_pass = 1'b0;
        check("queue fully drained after overflow test", {55'b0, dut.rx_count}, 64'd0);

        /*
         * -- 3. Byte-lane isolation -- a single access touching two
         * lanes at once (LCR + SCR) updates exactly those two registers
         * and no others; a subsequent single-lane read of each confirms
         * neither leaked into the other. (LCR value 0x2A deliberately
         * keeps bit 7/DLAB clear -- DLAB round-trip gets its own section
         * below.)
         */
        wb_cycle(32'h0, (64'h2A << 24) | (64'h55 << 56), SEL3 | SEL7, 1'b1);
        wb_cycle(32'h0, 64'h0, SEL3, 1'b0);
        check("LCR write (combined lanes): reads back 0x2A", dat_o[31:24], 64'h2A);
        wb_cycle(32'h0, 64'h0, SEL7, 1'b0);
        check("SCR write (combined lanes): reads back 0x55, unaffected by LCR's own write", dat_o[63:56], 64'h55);

        /*
         * -- 4. DLAB round-trip -- offset 0/1 alias to DLL/DLM while
         * DLAB=1, and do NOT touch THR/RBR/IER while DLAB=1.
         */
        begin
            logic [63:0] tx_count_before_dlab;
            wb_cycle(32'h0, 64'h0, SEL1, 1'b0);
            check("IER reads 0 before DLAB section (sanity)", dat_o[15:8], 64'h0);

            wb_cycle(32'h0, (64'h80 << 24), SEL3, 1'b1); // LCR <- DLAB=1, rest 0
            tx_count_before_dlab = {55'b0, dut.tx_history_count};

            wb_cycle(32'h0, 64'h11, SEL0, 1'b1); // DLL <- 0x11 (NOT a THR write)
            wb_cycle(32'h0, (64'h22 << 8), SEL1, 1'b1); // DLM <- 0x22 (NOT an IER write)

            check("a lane-0 write while DLAB=1 does not print/capture (DLL, not THR)",
                {55'b0, dut.tx_history_count}, tx_count_before_dlab);

            wb_cycle(32'h0, 64'h0, SEL0, 1'b0);
            check("lane 0 read while DLAB=1 returns DLL, not RBR", dat_o[7:0], 64'h11);
            wb_cycle(32'h0, 64'h0, SEL1, 1'b0);
            check("lane 1 read while DLAB=1 returns DLM, not IER", dat_o[15:8], 64'h22);

            wb_cycle(32'h0, 64'h0, SEL3, 1'b1); // LCR <- 0 (DLAB=0, dat_i defaults to 0)
            wb_cycle(32'h0, 64'h0, SEL0, 1'b0);
            check("lane 0 read after DLAB=0 returns RBR again (empty queue reads 0), not stale DLL",
                dat_o[7:0], 64'h0);
            wb_cycle(32'h0, 64'h0, SEL1, 1'b0);
            check("lane 1 read after DLAB=0 returns IER again (still 0), not stale DLM",
                dat_o[15:8], 64'h0);
        end

        /*
         * -- 5. IER-gates-RDA -- the single most important regression
         * check versus the old uart_rx.sv's unconditional o_rx_irq.
         */
        dut.push_byte(8'h5A);
        wb_cycle(32'h0, 64'h0, SEL5, 1'b0);
        check("sanity: LSR.DR is set (byte genuinely queued)", dat_o[40], 64'd1);
        check("o_irq stays low with IER bit0=0 despite rx_count>0", {63'b0, irq}, 64'd0);

        wb_cycle(32'h0, (64'h1 << 8), SEL1, 1'b1); // IER.RDA <- 1, no new byte pushed
        check("o_irq rises the instant IER bit0 is set, with no new byte", {63'b0, irq}, 64'd1);

        wb_cycle(32'h0, 64'h0, SEL0, 1'b0); // drain the byte
        check("o_irq drops once the queue is drained", {63'b0, irq}, 64'd0);

        /*
         * -- 6. IIR priority encode: {none, RDA, THRE, RDA+THRE} --
         * IER bit0 (RDA) is already 1 from section 5; arm bit1 (THRE)
         * too, needed for the THRE/combined cases below.
         */
        wb_cycle(32'h0, (64'h3 << 8), SEL1, 1'b1); // IER <- RDA|THRE enabled

        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);
        check("IIR: none pending -> 0x01 (ID=000, bit0=1)", dat_o[23:16], 64'h01);

        dut.push_byte(8'h7E); // makes RDA pending (IER bit0 already 1)
        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);
        check("IIR: RDA only pending -> 0x04 (ID=010, bit0=0)", dat_o[23:16], 64'h04);
        wb_cycle(32'h0, 64'h0, SEL0, 1'b0); // drain -- back to none pending
        check("RBR pop drained the RDA-priming byte", dat_o[7:0], 64'h7E);

        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);
        check("IIR: back to none pending after RDA drains", dat_o[23:16], 64'h01);

        wb_cycle(32'h0, 64'h33, SEL0, 1'b1); // THR write -- arms THRE (IER bit1=1)
        /*
         * #1 settle: o_irq's own thr_write_this_cycle mask is a
         * continuous assign off cyc_i/stb_i, which wb_cycle() itself
         * clears via a blocking assignment right before returning --
         * reading o_irq in the SAME zero-time window (no intervening
         * delay) risks the exact stale-combinational-read race
         * testbench/wb_driver.sv's own header already documents by name
         * for ack_o, just manifesting here for o_irq instead. Confirmed
         * empirically (a standalone debug run showed thre_pending_q
         * already correctly 1 but irq misreading 0 at this exact point
         * without this settle).
         */
        #1;
        check("o_irq rises once THRE is armed (no RDA pending)", {63'b0, irq}, 64'd1);
        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);
        check("IIR: THRE only pending -> 0x02 (ID=001, bit0=0)", dat_o[23:16], 64'h02);
        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);
        check("IIR read that reports THRE clears it -- next read is back to none", dat_o[23:16], 64'h01);
        check("o_irq drops once THRE clears (no RDA pending)", {63'b0, irq}, 64'd0);

        /*
         * -- 7. THRE one-shot full cycle: write -> settle -> pending ->
         * IIR-read-clears -> re-arm-on-next-write.
         */
        wb_cycle(32'h0, 64'h44, SEL0, 1'b1); // THR write -- arm
        #1; // settle -- see section 6's own comment on this exact race
        check("THRE armed after THR write (settled by the time wb_cycle returns)", {63'b0, irq}, 64'd1);
        // The IIR read that REPORTS THRE is the same one that triggers
        // the clear -- the clear itself only becomes visible on the NEXT
        // read (registered, one cycle later), same as section 6's own
        // two-read pattern above -- NOT the same read, which still
        // correctly reports the pending cause it's telling software about.
        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);  // IIR read -- reports THRE, arms the clear
        check("IIR reports THRE pending on this read", dat_o[23:16], 64'h02);
        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);  // second read -- confirms the clear took effect
        check("IIR read clears THRE -- next read is back to none", dat_o[23:16], 64'h01);
        check("o_irq low after THRE clears", {63'b0, irq}, 64'd0);
        wb_cycle(32'h0, 64'h55, SEL0, 1'b1); // a second THR write -- re-arms
        #1; // settle
        check("THRE re-armed by a fresh THR write", {63'b0, irq}, 64'd1);
        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);  // reports THRE again
        check("IIR reports THRE again after re-arm", dat_o[23:16], 64'h02);
        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);  // drain it again for the sections below
        check("THRE cleared again", dat_o[23:16], 64'h01);

        /*
         * -- 8. Revert-and-recheck directed tests (this plan's own named
         * mutants) -- get RDA and THRE BOTH genuinely pending at once.
         */
        dut.push_byte(8'h66);                // RDA pending (IER bit0 still 1)
        wb_cycle(32'h0, 64'h77, SEL0, 1'b1);  // THR write -- arms THRE (IER bit1 still 1)
        #1; // settle
        check("setup: o_irq high with both RDA and THRE pending", {63'b0, irq}, 64'd1);

        // 8a. IIR wrong-priority mutant's own directed test: RDA must
        // outrank THRE.
        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);
        check("IIR priority: reports RDA (0x04), not THRE, when both pending", dat_o[23:16], 64'h04);

        // 8b. Wrong-clear-condition mutant's own directed test: that RDA
        // read must NOT have touched THRE -- drain RDA, then confirm THRE
        // is still there (reported, and clears for real only now).
        wb_cycle(32'h0, 64'h0, SEL0, 1'b0);
        check("RDA-priming byte drained", dat_o[7:0], 64'h66);
        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);
        check("IIR priority: THRE survived the earlier RDA-reporting read, reports now (0x02)",
            dat_o[23:16], 64'h02);
        wb_cycle(32'h0, 64'h0, SEL2, 1'b0);
        check("IIR: back to none pending after THRE genuinely clears", dat_o[23:16], 64'h01);

        // 8c. Bonus mutant's own directed test: a new THR write while
        // THRE is already pending drops o_irq for exactly the cycle the
        // write is in flight, then re-arms -- driven directly (not via
        // wb_cycle()) so the in-flight value is observable.
        wb_cycle(32'h0, 64'h88, SEL0, 1'b1); // arm THRE fresh, no RDA pending
        #1; // settle
        check("bonus-mutant setup: THRE pending, o_irq high", {63'b0, irq}, 64'd1);

        while (ack) @(posedge clk); // settle, same discipline as clint_tb.sv's own ack-timing test
        @(negedge clk);
        addr = 32'h0; dat_i = 64'h99; sel = SEL0; we = 1'b1; cyc = 1'b1; stb = 1'b1;
        #1;
        check("bonus mutant: o_irq drops while the new THR write is in flight",
            {63'b0, irq}, 64'd0);
        @(posedge clk); #1;
        check("bonus mutant: o_irq still masked right as ack fires (cyc/stb still asserted)",
            {63'b0, irq}, 64'd0);
        cyc = 0; stb = 0;
        #1;
        check("bonus mutant: o_irq re-arms once the write's own bus cycle completes",
            {63'b0, irq}, 64'd1);
        @(negedge clk);

        wb_cycle(32'h0, 64'h0, SEL2, 1'b0); // reports THRE (this read arms the clear)
        check("cleanup: IIR reports THRE pending", dat_o[23:16], 64'h02);
        wb_cycle(32'h0, 64'h0, SEL2, 1'b0); // second read -- confirms cleared, leave state clean
        check("cleanup: THRE drained", dat_o[23:16], 64'h01);

        /*
         * -- 9. MCR reserved-bits-read-0 --
         */
        wb_cycle(32'h0, (64'hFF << 32), SEL4, 1'b1);
        wb_cycle(32'h0, 64'h0, SEL4, 1'b0);
        check("MCR: bits[4:0] stick", dat_o[36:32], 64'(5'h1F));
        check("MCR: bits[7:5] read back forced 0", dat_o[39:37], 64'h0);

        /*
         * -- 10. LCR full read-back fidelity (all 8 bits, including
         * DLAB itself) --
         */
        wb_cycle(32'h0, (64'hC7 << 24), SEL3, 1'b1);
        wb_cycle(32'h0, 64'h0, SEL3, 1'b0);
        check("LCR: full 8-bit read-back fidelity", dat_o[31:24], 64'hC7);
        wb_cycle(32'h0, (64'h00 << 24), SEL3, 1'b1); // clear DLAB back to 0, tidy exit state

        /*
         * -- 11. err_o never asserts, for a representative spread of
         * accesses across every lane.
         */
        wb_cycle(32'h0, 64'h0, SEL0, 1'b0);
        check("err_o never asserts (RBR read)", {63'b0, err}, 64'd0);
        wb_cycle(32'h0, 64'h0, SEL6, 1'b0);
        check("err_o never asserts (MSR read)", {63'b0, err}, 64'd0);
        wb_cycle(32'h0, 64'hAA, SEL0, 1'b1);
        check("err_o never asserts (THR write)", {63'b0, err}, 64'd0);

        // MSR is fully hardwired -- confirm its real value now that
        // every other section is done touching the bus.
        wb_cycle(32'h0, 64'h0, SEL6, 1'b0);
        check("MSR reads the hardwired 8'b1011_0000 (CTS/DSR/DCD=1, RI=0)", dat_o[55:48], 64'hB0);

        $display("");
        $display("uart16550_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("uart16550_tb: FAILURES PRESENT");
        $finish;
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
