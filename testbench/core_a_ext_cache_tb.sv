// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core_a_ext_cache_tb -- the AMO-through-cache invariant, as
 * an explicit regression check (not just a design-doc argument)
 *
 * Small and targeted, not a re-run of core_a_ext_tb.sv's full 22-instruction
 * program (427 lines of hand-encoded instructions -- not worth duplicating
 * wholesale just to add one new white-box check; core_c_ext_cache_tb.sv/
 * core_m_ext_cache_tb.sv already give this milestone's D$/I$-composition
 * coverage more broadly).
 *
 * Proves, via the D$'s own downstream-beat count, the specific invariant
 * design/cache_complex.sv's header and the session plan both argue for
 * but don't themselves verify: an AMO's read phase (S_MEM) may genuinely
 * miss and refill a whole line, but the write phase (S_AMO_WRITE) is
 * PROVABLY always a cache hit afterward -- never its own refill, since
 * amo_addr_q is captured once and reused bit-identically for both phases
 * (design/core.sv:~1482), so a direct-mapped index/tag guarantees both
 * phases hit the same line.
 *
 * Setup deliberately arranges a COLD line: `sw` to a never-before-touched
 * address is itself a D$ write-MISS (no-write-allocate -- doesn't install
 * the line, see dcache.sv's own header), so the AMOADD.W that follows is
 * guaranteed to start from a genuinely uncached line, making the read
 * phase's miss (and the write phase's consequent hit) real, not
 * coincidental.
 */
module core_a_ext_cache_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_cache_harness #(.NUM_WORDS(256)) dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    wire halted = dut.core0.halted;
    `include "halt_wait.sv"

    /*
     * White-box, part 1: count dcache0's own downstream mem_cyc_o pulses
     * while core.sv sits in S_MEM (the AMO's read phase) -- same
     * rising-edge-pulse-counting idiom icache_tb.sv/dcache_tb.sv already
     * use -- confirms the read phase genuinely needed a refill (the
     * setup below deliberately arranges a cold line), not that it
     * happened to already be cached.
     */
    int read_phase_beats = 0;
    logic mem_cyc_q = 0;
    always @(posedge clk) begin
        if (dut.cache0.mem_cyc_o && !mem_cyc_q && dut.core0.state == 2'd2 /* S_MEM */)
            read_phase_beats <= read_phase_beats + 1;
        mem_cyc_q <= dut.cache0.mem_cyc_o;
    end

    /*
     * White-box, part 2: the actual invariant under test. A write is
     * ALWAYS exactly one downstream beat under write-through/
     * no-write-allocate, hit or miss (see dcache.sv's own header) -- so
     * downstream traffic alone can't distinguish "the write phase hit"
     * from "the write phase missed", unlike the read phase above. Sample
     * dcache0's own write_hit_q directly instead: it's captured once (on
     * the CACHE_IDLE->CACHE_WRITE transition) and held stable for the
     * whole CACHE_WRITE state's duration, so any sample taken while
     * dcache0 is genuinely in CACHE_WRITE (state_q==2'd2, this module's
     * own 3rd enum value) reflects the real answer for that beat.
     */
    logic write_phase_was_hit = 1'b0;
    logic write_phase_observed = 1'b0;
    always @(posedge clk) begin
        if (dut.cache0.dcache0.state_q == 2'd2 /* CACHE_WRITE */) begin
            write_phase_was_hit  <= dut.cache0.dcache0.write_hit_q;
            write_phase_observed <= 1'b1;
        end
    end

    initial begin
        #1; // run after wb4_sram's own time-0 init

        /*
         * idx  addr  instruction                    notes
         *  0   0x00  addi x28, x0, 800               scratch address, never touched before
         *  1   0x04  addi x29, x0, 100
         *  2   0x08  sw   x29, 0(x28)                D$ write-MISS, does NOT allocate the line
         *  3   0x0C  addi x30, x0, 5
         *  4   0x10  amoadd.w x1, x30, (x28)         x1 = 100 (old); mem becomes 105
         *  5   0x14  lw   x2, 0(x28)                 x2 = 105 -- confirms the write actually landed
         *  6   0x18  ebreak
         */
        dut.sram0.memory[0] = {encode_i(32'sd100, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),   // idx1
                                encode_i(32'sd800, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};  // idx0
        dut.sram0.memory[1] = {encode_i(32'sd5, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),     // idx3
                                encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE)};    // idx2
        dut.sram0.memory[2] = {encode_i(32'sd0, 5'd28, 3'b010, 5'd2, `OPC_LOAD),       // idx5
                                encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd1, `OPC_AMO)}; // idx4
        dut.sram0.memory[3] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),      // idx7 (padding)
                                {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};                    // idx6: ebreak

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "dut.core0.halted never went high");

        check("AMOADD.W: rd = old value", dut.core0.regfile0.gp_registers[1], 64'd100);
        check("AMOADD.W: memory updated (write actually reached SRAM)",
              dut.core0.regfile0.gp_registers[2], 64'd105);
        check("core halted (ebreak reached)", {63'b0, dut.core0.halted}, 64'd1);

        check("AMO read phase genuinely missed and refilled (cold line, per setup)",
              {63'b0, (read_phase_beats > 0)}, 64'd1);
        check("AMO write phase was genuinely observed", {63'b0, write_phase_observed}, 64'd1);
        check("AMO write phase was ALWAYS a cache hit (write_hit_q), never its own refill",
              {63'b0, write_phase_was_hit}, 64'd1);
        $display("(diagnostic) read phase: %0d downstream beats", read_phase_beats);

        $display("");
        $display("core_a_ext_cache_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_a_ext_cache_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
