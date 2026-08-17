// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, Zifencei (FENCE.I) -- a plain retire/no-op check, and
 * the real proof: a genuine self-modifying-code sequence where skipping
 * FENCE.I would execute stale I$ content, closing the gap soc.sv's own
 * header used to document as a known, deliberate limitation.
 *
 * Uses core_cache_harness.sv (the real core -> cache_complex -> icache0/
 * dcache0 -> wb4_sram path, with icache_flush_o correctly wired to
 * cache0.flush_i) -- a harness without the real cache in the loop would
 * prove nothing here, since the whole point is that a D$ store doesn't
 * automatically invalidate a stale I$ line.
 *
 * Test 2's construction, in order:
 *   1. `jal` to TARGET once -- TARGET's first instruction (`addi x5,x0,
 *      111`) fetches into I$ for the first time (a cold miss, installing
 *      the OLD bytes into that line).
 *   2. A D$ `sw` overwrites TARGET's first instruction with a different
 *      encoding (`addi x5,x0,222`) -- SRAM now holds the NEW bytes, but
 *      the I$ line from step 1 is untouched (write-through keeps D$'s
 *      OWN cached copy in lockstep with SRAM, but I$ has no idea D$ just
 *      wrote to an address it has cached).
 *   3. `fence.i` -- must invalidate the I$ line covering TARGET.
 *   4. `jal` to TARGET again -- must now be a genuine miss that re-fetches
 *      the NEW bytes from SRAM, executing `addi x5,x0,222`, not a stale
 *      hit re-serving the OLD `addi x5,x0,111` from step 1.
 * x5's final value (222, not 111) is therefore the direct proof: it can
 * only be 222 if the second call's fetch actually saw the new bytes.
 */
module core_fence_i_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_cache_harness dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    wire halted = dut.core0.halted;
    `include "halt_wait.sv"

    localparam int unsigned TARGET_ADDR = 32'h100; // line-aligned (default line size 32B)

    /*
     * The new instruction's raw encoding, and its LUI+ADDI split -- the
     * standard "li pseudo-op" construction (ADDI's 12-bit immediate is
     * sign-extended, so if its own bit 11 is set, the LUI half must be
     * incremented by 1 to compensate). Computed here as plain
     * SystemVerilog expressions, not hand-derived hex, so there's no
     * hand-arithmetic step that could be silently wrong -- the same
     * lesson this session's earlier hand-packed-word mistakes already
     * paid for once.
     */
    logic [31:0] new_instr;
    logic [19:0] new_instr_hi20;
    logic [11:0] new_instr_lo12;

    logic [31:0] main_prog[0:19];
    logic [31:0] target_prog[0:1];
    int i;

    initial begin
        #1;

        new_instr      = encode_i(32'sd222, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM);
        new_instr_lo12 = new_instr[11:0];
        new_instr_hi20 = new_instr[31:12] + (new_instr_lo12[11] ? 20'd1 : 20'd0);

        /*
         * ---- Test 1: FENCE.I retire/no-op, addr 0x00-0x0B ----
         * addr  instr                          notes
         * 0x00  addi x3, x0, 999                sentinel -- FENCE.I must not touch it
         * 0x04  fence.i                         must retire cleanly: no trap, no reg write
         * 0x08  addi x4, x0, 111                resume marker -- proves clean retirement
         */
        main_prog[0] = encode_i(32'sd999, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM);
        main_prog[1] = {17'b0, 3'b001, 5'b0, 7'b0001111}; // fence.i
        main_prog[2] = encode_i(32'sd111, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM);

        /*
         * ---- Test 2: self-modifying code, addr 0x0C-0x3B ----
         * addr  instr                          notes
         * 0x0C  jal x1, TARGET                  call #1 -- populates I$ with OLD bytes
         * 0x10  addi x6, x0, 1                  "call #1 returned" marker
         * 0x14  lui x9, new_instr_hi20           x9 <- new instruction encoding, part 1
         * 0x18  addi x9, x9, new_instr_lo12      x9 <- new instruction encoding, part 2
         * 0x1C  addi x10, x0, TARGET_ADDR        x10 <- TARGET's address (data pointer)
         * 0x20  sw x9, 0(x10)                    D$ STORE overwrites TARGET's first instr
         * 0x24  fence.i                          flush I$
         * 0x28  jal x1, TARGET                   call #2 -- must see NEW bytes (x1 again --
         *                                          TARGET's own jalr always returns via x1)
         * 0x2C  addi x11, x0, 1                  "call #2 returned" marker
         * 0x30  ebreak
         */
        main_prog[3]  = encode_j(int'(TARGET_ADDR) - 32'h0C, 5'd1, `OPC_JAL);
        main_prog[4]  = encode_i(32'sd1, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM);
        main_prog[5]  = encode_u(new_instr_hi20, 5'd9, `OPC_LUI);
        main_prog[6]  = encode_i(int'($signed(new_instr_lo12)), 5'd9, 3'b000, 5'd9, `OPC_OP_IMM);
        main_prog[7]  = encode_i(int'(TARGET_ADDR), 5'd0, 3'b000, 5'd10, `OPC_OP_IMM);
        main_prog[8]  = encode_s(32'sd0, 5'd9, 5'd10, 3'b010, `OPC_STORE); // sw x9,0(x10)
        main_prog[9]  = {17'b0, 3'b001, 5'b0, 7'b0001111}; // fence.i
        main_prog[10] = encode_j(int'(TARGET_ADDR) - 32'h28, 5'd1, `OPC_JAL); // x1 -- TARGET's own
            // jalr always returns via x1 (hardcoded there), so BOTH calls must link into x1, not a
            // distinct register per call -- using x2 here originally sent the second call back to
            // the FIRST call's stale return address instead, an authoring bug caught by exactly the
            // kind of PC trace this session's earlier hand-packed-word mistakes were also caught by.
        main_prog[11] = encode_i(32'sd1, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM);
        main_prog[12] = encode_i(32'sd1, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM); // ebreak

        for (i = 0; i < 6; i = i + 1)
            dut.sram0.memory[i] = {main_prog[2*i+1], main_prog[2*i]};
        dut.sram0.memory[6][31:0] = main_prog[12]; // 0x30: ebreak, alone in its word's low half

        /*
         * addr    instr                        notes
         * 0x100   addi x5, x0, 111              OLD instruction -- will be overwritten
         * 0x104   jalr x0, x1, 0                return via the caller's own link register
         */
        target_prog[0] = encode_i(32'sd111, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM);
        target_prog[1] = encode_i(32'sd0, 5'd1, 3'b000, 5'd0, `OPC_JALR);

        dut.sram0.memory[int'(TARGET_ADDR) >> 3] = {target_prog[1], target_prog[0]};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "dut.core0.halted never went high");

        check("FENCE.I: sentinel untouched", dut.core0.regfile0.gp_registers[3], 64'd999);
        check("FENCE.I: resumed cleanly (no trap, no hang)", dut.core0.regfile0.gp_registers[4], 64'd111);

        check("self-modifying code: call #1 returned", dut.core0.regfile0.gp_registers[6], 64'd1);
        check("self-modifying code: call #2 returned", dut.core0.regfile0.gp_registers[11], 64'd1);
        check({"self-modifying code: second call executed the NEW instruction (222), ",
            "not a stale I$ hit serving the OLD one (111) -- the actual proof FENCE.I closes the gap"},
            dut.core0.regfile0.gp_registers[5], 64'd222);

        check("core halted (ebreak reached)", {63'b0, dut.core0.halted}, 64'd1);

        $display("");
        $display("core_fence_i_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_fence_i_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
