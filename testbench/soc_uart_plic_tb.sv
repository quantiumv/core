// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: end-to-end UART-RX-through-PLIC test against the REAL
 * soc.sv topology (core+decoder+cache+sram+uart_tx+uart_rx+clint+plic)
 * and real toolchain-assembled programs (firmware/uart_plic_meip_test.s,
 * firmware/uart_plic_seip_test.s) -- the final proof of the whole
 * PMP+PLIC staged plan: a real byte arriving at uart_rx0, through a
 * real plic0 gateway/claim/complete cycle, through csr_file0's real
 * mip.MEIP/SEIP splice, through core0's real interrupt-taking priority
 * mux, actually redirects execution end to end, exactly as wired in
 * soc.sv -- not just in isolation (design/plic_tb.sv already proves
 * plic.sv's own internal semantics; testbench/core_interrupt_tb.sv
 * already proves core.sv's own MEI/priority mux in isolation with a
 * hand-packed program and a directly-driven i_meip).
 *
 * Two independent DUT instances, mirroring core_interrupt_tb.sv's own
 * "N independent cases, not N phases of one program" convention:
 *   dut_meip: undelegated M-mode path (mcause, not scause; current_priv
 *     is M throughout the real handler).
 *   dut_seip: delegated S-mode path (mideleg[9]=1, genuinely delegated
 *     -- scause/sepc, not mcause/mepc; current_priv is S throughout the
 *     real handler) -- the real, Linux-realistic shape a PLIC actually
 *     exists for. "Throughout the real handler," not "at the end of the
 *     program," because crt0.s's own trailing ebreak is never delegated
 *     and unavoidably bounces through M-mode afterward regardless of
 *     which test this is -- see the snapshot block below for why every
 *     check reads a point-in-time capture, not live state.
 *
 * Deliberately NOT repeated here: a dual-context-simultaneous scenario
 * (both contexts enabled, racing to claim the same pending request) --
 * design/plic_tb.sv's own "dual-context multicast" test already proves
 * that property directly and more cheaply (no real toolchain/soc
 * topology needed to exercise plic.sv's own internal gateway logic);
 * repeating it here through a whole firmware program would mostly
 * re-prove the same PLIC-internal property already covered, not add
 * meaningfully to the real end-to-end proof this file exists for.
 *
 * The triggering UART byte is injected via dut_*.uart_rx0.push_byte()
 * once, early (right after reset, well before either program's own
 * first instruction could possibly touch RX_DATA/PLIC) -- see
 * firmware/uart_plic_meip_test.s's own header for why this avoids any
 * race with the pop each handler does far later.
 *
 * Follows testbench/soc_interrupt_tb.sv's exact loading convention: a
 * #1-delayed $readmemh override of dut_*.sram0.memory, run AFTER
 * wb4_sram's own time-0 zero-fill+crt0.hex init.
 */
module soc_uart_plic_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    soc dut_meip (.clk(clk), .rst(rst));
    soc dut_seip (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    logic meip_halted = 1'b0;
    logic seip_halted = 1'b0;
    always @(posedge clk) if (dut_meip.core0.trap_taken && dut_meip.core0.is_ebreak) meip_halted <= 1'b1;
    always @(posedge clk) if (dut_seip.core0.trap_taken && dut_seip.core0.is_ebreak) seip_halted <= 1'b1;
    // halt_wait.sv's own wait_halted_or_timeout requires a signal
    // literally named `halted` in this module's own scope -- combined
    // here (both DUTs must reach their own terminal ebreak) since this
    // file, unlike soc_interrupt_tb.sv, drives two independent DUTs.
    wire halted = meip_halted && seip_halted;
    `include "halt_wait.sv"

    /*
     * Point-in-time snapshots of s1/s3/s4/current_priv/mcause_q(or
     * scause_q), taken at MRET's/SRET's own commit edge -- the LAST
     * instruction of the real handler, one full instruction after the
     * marker write (li s1,1) so its own effect is already visible, and
     * several instructions after the claim/pop, so THEIRS are too --
     * NOT read live at check() time. This is load-bearing, not just
     * defensive: mtvec/stvec stay armed at these same handlers through
     * crt0.s's own trailing ebreak (never delegated, so it ALWAYS
     * bounces through mtvec regardless of which test this is), which
     * re-executes the ENTIRE handler body a second time with the real
     * PLIC gateway now quiescent and the RX queue now empty -- a claim
     * on that second pass genuinely returns ID 0, and a pop genuinely
     * returns 0, corrupting s3/s4 (though NOT s1, which is safe to read
     * live since both passes write it the identical constant) if read
     * live after that second pass has already happened. Same class of
     * bug (and same fix) testbench/soc_interrupt_tb.sv's own header
     * documents in full for mcause_q there.
     */
    logic [63:0] meip_s1_snap, meip_s3_snap, meip_s4_snap, meip_mcause_snap;
    logic [1:0]  meip_priv_snap;
    logic        meip_state_captured = 1'b0;
    always @(posedge clk) if (!meip_state_captured && dut_meip.core0.commit_now && dut_meip.core0.pc == 64'hac) begin
        meip_state_captured <= 1'b1;
        meip_s1_snap    <= dut_meip.core0.regfile0.gp_registers[9];
        meip_s3_snap    <= dut_meip.core0.regfile0.gp_registers[19];
        meip_s4_snap    <= dut_meip.core0.regfile0.gp_registers[20];
        meip_priv_snap  <= dut_meip.core0.current_priv;
        meip_mcause_snap <= dut_meip.core0.csr_file0.mcause_q;
    end

    logic [63:0] seip_s1_snap, seip_s3_snap, seip_s4_snap, seip_mcause_snap, seip_scause_snap;
    logic [1:0]  seip_priv_snap;
    logic        seip_state_captured = 1'b0;
    always @(posedge clk) if (!seip_state_captured && dut_seip.core0.commit_now && dut_seip.core0.pc == 64'he4) begin
        seip_state_captured <= 1'b1;
        seip_s1_snap     <= dut_seip.core0.regfile0.gp_registers[9];
        seip_s3_snap     <= dut_seip.core0.regfile0.gp_registers[19];
        seip_s4_snap     <= dut_seip.core0.regfile0.gp_registers[20];
        seip_priv_snap   <= dut_seip.core0.current_priv;
        seip_mcause_snap <= dut_seip.core0.csr_file0.mcause_q;
        seip_scause_snap <= dut_seip.core0.csr_file0.scause_q;
    end

    localparam int TIMEOUT_CYCLES_UART_PLIC = 5000;

    initial begin
        #1; // run after wb4_sram's own time-0 init (see header comment)
        $readmemh("../firmware/uart_plic_meip_test.hex", dut_meip.sram0.memory);
        $readmemh("../firmware/uart_plic_seip_test.hex", dut_seip.sram0.memory);

        @(posedge clk); #1;
        rst = 0;

        // Inject the triggering byte into each DUT's own UART RX queue
        // -- once, real early, well before either program's own first
        // instruction could reach RX_DATA/PLIC (see header).
        dut_meip.uart_rx0.push_byte(8'h5A);
        dut_seip.uart_rx0.push_byte(8'hA5);

        wait_halted_or_timeout(TIMEOUT_CYCLES_UART_PLIC, "EBREAK trap never fired -- are the uart_plic_*_test.hex images built?");

        /*
         * ---- dut_meip checks (undelegated M-mode path) ----
         * s1/s3/s4/current_priv/mcause_q all read from the point-in-time
         * snapshot above, NOT live -- see that block's own comment for why.
         */
        check("meip: final-state sample was captured (sanity on the monitor itself)",
            {63'b0, meip_state_captured}, 64'd1);
        check("meip: s1 (handler marker) -- real MEI fired end-to-end", meip_s1_snap, 64'd1);
        check("meip: claim (s3) returned source 1's real ID", meip_s3_snap, 64'd1);
        check("meip: the real injected byte was popped (s4)", meip_s4_snap, 64'h5A);
        check("meip: mcause == standard machine-external-interrupt encoding (cause 11)",
            meip_mcause_snap, 64'h8000_0000_0000_000B);
        check("meip: current_priv == M during the real handler", {62'b0, meip_priv_snap}, 64'(2'b11));
        check("meip: EBREAK trap fired (real forward progress after the handler)", {63'b0, meip_halted}, 64'd1);
        check("meip: plic0 gateway quiescent after complete (o_meip deasserted)",
            {63'b0, dut_meip.plic0.o_meip}, 64'd0);

        /*
         * ---- dut_seip checks (delegated S-mode path -- the real,
         * Linux-realistic shape). s5 (undelegated-handler canary) is
         * safe to read live -- if the undelegated m_trap_handler ever
         * ran (a real routing bug), it's the ONLY thing that ever
         * writes s5, so no later bounce-back can un-corrupt it back to 0.
         */
        check("seip: undelegated m_trap_handler never ran (s5==0)", dut_seip.core0.regfile0.gp_registers[21], 64'd0);
        check("seip: final-state sample was captured (sanity on the monitor itself)",
            {63'b0, seip_state_captured}, 64'd1);
        check("seip: s1 (handler marker) -- real SEI fired, routed to S", seip_s1_snap, 64'd1);
        check("seip: claim (s3) returned source 1's real ID", seip_s3_snap, 64'd1);
        check("seip: the real injected byte was popped (s4)", seip_s4_snap, 64'hA5);
        check("seip: scause == standard machine-external-interrupt encoding (cause 9), NOT mcause",
            seip_scause_snap, 64'h8000_0000_0000_0009);
        check("seip: mcause_q untouched during the real handler (never routed to M)", seip_mcause_snap, 64'd0);
        check("seip: current_priv == S during the real handler", {62'b0, seip_priv_snap}, 64'(2'b01));
        check("seip: EBREAK trap fired (real forward progress after the handler)", {63'b0, seip_halted}, 64'd1);
        check("seip: plic0 gateway quiescent after complete (o_seip deasserted)",
            {63'b0, dut_seip.plic0.o_seip}, 64'd0);

        $display("");
        $display("soc_uart_plic_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("soc_uart_plic_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
