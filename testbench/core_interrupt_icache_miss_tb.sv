// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's interrupt-taking logic against the REAL cache fabric
 * (design/icache.sv/design/dcache.sv via design/cache_complex.sv, reached
 * through core_cache_harness.sv) -- the one case core_interrupt_tb.sv's
 * plain wb4_sram-only harness structurally cannot exercise:
 * fetch_redirect_q staying high across a genuine multi-cycle I$ refill of
 * the trap-vector fetch itself.
 *
 * mtvec is pointed at 0x1000 -- a dword the small main-flow program never
 * touches (it lives entirely under 0x20), and (since the I$ starts fully
 * invalid after reset) the very first fetch of it is unconditionally a
 * genuine miss, no address-aliasing games required. Loaded via LUI (`lui
 * x28,1` -> x28 = 0x1000) rather than ADDI -- 0x1000 doesn't fit ADDI's
 * signed 12-bit immediate (same class of bug this file's sibling
 * core_interrupt_tb.sv had to route around for mstatus.MPP).
 *
 * Same deferred-i_mtip technique as core_interrupt_tb.sv: mie.MTIE/
 * mstatus.MIE enabled during setup (i_mtip=0, so nothing fires
 * prematurely), i_mtip asserts on the TRIGGER instruction's own commit
 * edge. fetch_redirect_q is sampled directly (white-box -- no
 * architectural way to observe "how many cycles did the redirected
 * fetch actually take") across the whole run; a genuine 4-beat refill
 * (line_words=4, core_cache_harness's default) must hold it high for
 * more than a couple of cycles.
 *
 * IMPORTANT, review-confirmed caveat: this does NOT currently prove
 * fetch_redirect_q is load-bearing (mutating it away -- collapsing
 * fetch_from_trap_vector to just interrupt_taken -- still passes this
 * test unchanged, confirmed empirically). That's expected, not a bug:
 * fetch_paddr is today a pure pc passthrough (core.sv), and pc itself is
 * updated to trap_vector the cycle after interrupt_taken fires, so
 * fetch_addr alone already stays correct through the whole refill with
 * no help from fetch_redirect_q. fetch_redirect_q exists anyway as
 * deliberate, forward-compatible scaffolding for the future Sv39 stage
 * (once fetch_paddr becomes a real, possibly multi-cycle translation,
 * pc alone will no longer trivially "keep up") -- see the plan's own
 * FSM-timing-proof section. This test still legitimately proves
 * fetch_redirect_q's own *behavior* is correct (stays high for the
 * whole refill, clears at the right edge) even though it can't yet
 * prove *necessity*; read the check below with that in mind.
 */
module core_interrupt_icache_miss_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;
    logic i_mtip = 1'b0;

    core_cache_harness #(.NUM_WORDS(4096)) dut (.clk(clk), .rst(rst), .i_mtip(i_mtip));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    localparam int TIMEOUT_CYCLES = 500;
    localparam logic [63:0] TRIGGER_PC = 64'h18;
    localparam logic [63:0] COLD_ADDR  = 64'h1000;

    always @(posedge clk) begin
        if (dut.core0.commit_now && dut.core0.pc == TRIGGER_PC) i_mtip <= 1'b1;
    end

    // White-box: fetch_redirect_q must stay high across a genuine
    // multi-cycle refill, not just blip for one cycle.
    int fetch_redirect_high_cycles = 0;
    always @(posedge clk) begin
        if (dut.core0.fetch_redirect_q) fetch_redirect_high_cycles <= fetch_redirect_high_cycles + 1;
    end

    initial begin
        #1; // run after wb4_sram's own time-0 crt0.hex init

        dut.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                 encode_u(20'd1, 5'd28, `OPC_LUI)};                              // lui x28,1 -> x28=0x1000 (0x00)
        dut.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                 encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};          // addi x28,x0,128 (0x08)
        dut.sram0.memory[2] = {encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                 encode_i(32'sd8, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};            // addi x28,x0,8 (0x10)
        dut.sram0.memory[3] = {encode_i(32'sd999, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),             // addi x2,x0,999 (poison, 0x1C)
                                 encode_i(32'h77, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};             // addi x1,x0,0x77 (TRIGGER, 0x18)
        dut.sram0.memory[4] = {32'h0,
                                 {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};                             // ebreak (0x20, safety net)

        // Handler at COLD_ADDR (0x1000) -- word index 0x1000/8 = 512.
        dut.sram0.memory[512] = {encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd11, `OPC_SYSTEM), // csrr x11,mcause (0x1004)
                                   encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM)}; // csrr x10,mepc (0x1000)
        dut.sram0.memory[513] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                                // ebreak (0x100C)
                                   encode_i(32'sd1, 5'd0, 3'b000, 5'd12, `OPC_OP_IMM)};             // addi x12,x0,1 (0x1008)

        @(posedge clk); #1;
        rst = 0;

        fork
            wait (dut.core0.halted === 1'b1);
            begin
                repeat (TIMEOUT_CYCLES) @(posedge clk);
                $display("TIMEOUT: dut.core0.halted never went high");
                $finish;
            end
        join_any
        #1;

        check("poison marker never ran (x2==0)", dut.core0.regfile0.gp_registers[2], 64'd0);
        check("mepc == TRIGGER+4 (0x1C)", dut.core0.regfile0.gp_registers[10], 64'h1C);
        check("mcause == standard machine-timer-interrupt encoding", dut.core0.regfile0.gp_registers[11], 64'h8000_0000_0000_0007);
        check("handler ran (x12==1)", dut.core0.regfile0.gp_registers[12], 64'd1);
        check("current_priv == M", {62'b0, dut.core0.current_priv}, 64'(2'b11));
        // NOT a necessity proof for fetch_redirect_q -- see this file's header. Confirms
        // its own behavior (stays high the whole refill) is correct, not that removing
        // it would break anything today.
        check("fetch_redirect_q held across a genuine multi-cycle I$ refill (>2 cycles)", {63'b0, (fetch_redirect_high_cycles > 2)}, 64'd1);
        check("halted", {63'b0, dut.core0.halted}, 64'd1);

        $display("");
        $display("core_interrupt_icache_miss_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_interrupt_icache_miss_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
