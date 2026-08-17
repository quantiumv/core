// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, M extension (integer multiply/divide) end to end
 *
 * All 13 M instructions through the real fetch -> decode -> execute ->
 * writeback path: MUL/MULH/MULHSU/MULHU/MULW (multiply) and DIV/DIVU/
 * REM/REMU/DIVW/DIVUW/REMW/REMUW (divide). Unit-level correctness for
 * the multiply ops and the divider itself is already proven by
 * design/alu_tb.sv and design/divider_tb.sv -- this file's job is
 * different: prove the DECODE and CONTROL-UNIT wiring routes each
 * instruction to the right place with the right operands, not re-derive
 * the arithmetic. Most operand pairs below are deliberately the exact
 * same ones already hand-verified in those two files, so any mismatch
 * here points squarely at the core.sv/decoder.sv wiring, not the
 * underlying math.
 *
 * The one thing this file proves that neither of those can: that a real
 * divide genuinely holds S_EXEC for more than one cycle, not just that
 * it eventually produces the right answer. A subtly broken div_stall/
 * i_start pulse (see core.sv's "M extension: divide" section) could let
 * the FSM race ahead and read the divider's output before it's actually
 * done -- on some inputs that could even coincidentally produce a
 * plausible-looking wrong answer. The white-box cycle-count check below
 * (watching dut.core0.state/dut.core0.pc directly) is what actually
 * rules that out; a register-value check alone can't.
 *
 * Uses the shared testbench/ infrastructure (check_lib.sv, halt_wait.sv,
 * core_wb4_sram_harness.sv), same as every testbench written since that
 * environment was built.
 */
module core_m_ext_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_wb4_sram_harness #(.NUM_WORDS(256)) dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    wire halted = dut.core0.halted;
    `include "halt_wait.sv"

    /*
     * White-box multi-cycle divide check. DIV (the program's first
     * divide-family instruction) lands at byte address 0x44 (idx17 --
     * see the memory layout comment below). Count consecutive cycles
     * dut.core0.state reads S_EXEC while dut.core0.pc reads that
     * address -- a genuine ~64-cycle iterative divide should hold there
     * for dozens of cycles, not 1.
     */
    localparam logic [63:0] DIV_PC = 64'h44;
    int div_exec_cycle_count = 0;
    int div_exec_cycle_count_final = 0;
    logic div_pc_seen = 1'b0;
    always @(posedge clk) begin
        if (dut.core0.pc == DIV_PC && dut.core0.state == 2'd1 /* S_EXEC */) begin
            div_exec_cycle_count <= div_exec_cycle_count + 1;
            div_pc_seen <= 1'b1;
        end else if (div_pc_seen) begin
            // left the DIV instruction's S_EXEC window -- latch the final count once
            if (div_exec_cycle_count_final == 0) div_exec_cycle_count_final <= div_exec_cycle_count;
        end
    end

    initial begin
        #1; // run after wb4_sram's own time-0 init -- see core_wb_tb.sv's header

        /*
         * idx  addr  instruction                       notes
         *  0   0x00  addi x20, x0, -1                  x20 = -1
         *  1   0x04  addi x21, x0, 2                    x21 = 2
         *  2   0x08  mul  x1, x20, x21                  x1 = 0xFFFF...FFFE           [CHECK: MUL]
         *  3   0x0C  addi x20, x0, 1                    x20 = 1
         *  4   0x10  slli x20, x20, 63                  x20 = INT64_MIN
         *  5   0x14  mulh x2, x20, x21                  x2 = 0xFFFF...FFFF (x21 still =2) [CHECK: MULH]
         *  6   0x18  addi x20, x0, -1                   x20 = -1 (signed operand for MULHSU)
         *  7   0x1C  addi x21, x0, -1                   x21 = -1's bit pattern (unsigned operand)
         *  8   0x20  mulhsu x3, x20, x21                x3 = 0xFFFF...FFFF            [CHECK: MULHSU]
         *  9   0x24  mulhu  x4, x20, x21                x4 = 0xFFFF...FFFE (reuse x20/x21) [CHECK: MULHU]
         * 10   0x28  addi x20, x0, -1
         * 11   0x2C  slli x20, x20, 32
         * 12   0x30  srli x20, x20, 32                  x20 = 0x00000000FFFFFFFF
         * 13   0x34  addi x21, x0, 2                    x21 = 2
         * 14   0x38  mulw x5, x20, x21                  x5 = 0xFFFF...FFFE            [CHECK: MULW]
         * 15   0x3C  addi x20, x0, -100                 x20 = -100
         * 16   0x40  addi x21, x0, 7                     x21 = 7
         * 17   0x44  div  x6, x20, x21                  x6 = -14                      [CHECK: DIV] (multi-cycle -- monitored)
         * 18   0x48  addi x20, x0, -1
         * 19   0x4C  addi x21, x0, 3
         * 20   0x50  divu x7, x20, x21                  x7 = 0x5555555555555555       [CHECK: DIVU]
         * 21   0x54  addi x20, x0, -100
         * 22   0x58  addi x21, x0, 7
         * 23   0x5C  rem  x8, x20, x21                  x8 = -2                       [CHECK: REM]
         * 24   0x60  addi x20, x0, 100
         * 25   0x64  addi x21, x0, 7
         * 26   0x68  remu x9, x20, x21                  x9 = 2                        [CHECK: REMU]
         * 27   0x6C  addi x20, x0, 1
         * 28   0x70  slli x20, x20, 31                  x20 = 0x0000000080000000
         * 29   0x74  addi x21, x0, 2
         * 30   0x78  divw x10, x20, x21                 x10 = 0xFFFFFFFFC0000000      [CHECK: DIVW]
         * 31   0x7C  addi x20, x0, -1
         * 32   0x80  slli x20, x20, 32
         * 33   0x84  srli x20, x20, 32                  x20 = 0x00000000FFFFFFFF
         * 34   0x88  addi x21, x0, 3
         * 35   0x8C  divuw x11, x20, x21                x11 = 0x0000000055555555      [CHECK: DIVUW]
         * 36   0x90  addi x20, x0, 1
         * 37   0x94  slli x20, x20, 31                  x20 = 0x0000000080000000
         * 38   0x98  addi x20, x20, 5                   x20 = 0x0000000080000005 (low 32 bits = 32-bit -2^31+5)
         * 39   0x9C  addi x21, x0, 2
         * 40   0xA0  remw x12, x20, x21                 x12 = 0xFFFFFFFFFFFFFFFF (-1) [CHECK: REMW]
         * 41   0xA4  addi x20, x0, -1
         * 42   0xA8  slli x20, x20, 32
         * 43   0xAC  srli x20, x20, 32
         * 44   0xB0  addi x20, x20, -1                  x20 = 0x00000000FFFFFFFE
         * 45   0xB4  addi x21, x0, 3
         * 46   0xB8  remuw x13, x20, x21                x13 = 2                       [CHECK: REMUW]
         * 47   0xBC  ebreak
         */
        dut.sram0.memory[0]  = {encode_i(32'sd2, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM),                    // idx1
                                 encode_i(-32'sd1, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM)};                  // idx0
        dut.sram0.memory[1]  = {encode_i(32'sd1, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM),                     // idx3
                                 encode_r(7'b0000001, 5'd21, 5'd20, 3'b000, 5'd1, `OPC_OP)};             // idx2: mul
        dut.sram0.memory[2]  = {encode_r(7'b0000001, 5'd21, 5'd20, 3'b001, 5'd2, `OPC_OP),              // idx5: mulh
                                 encode_shift64(6'b000000, 6'd63, 5'd20, 3'b001, 5'd20, `OPC_OP_IMM)};   // idx4
        dut.sram0.memory[3]  = {encode_i(-32'sd1, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM),                    // idx7
                                 encode_i(-32'sd1, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM)};                   // idx6
        dut.sram0.memory[4]  = {encode_r(7'b0000001, 5'd21, 5'd20, 3'b011, 5'd4, `OPC_OP),              // idx9: mulhu
                                 encode_r(7'b0000001, 5'd21, 5'd20, 3'b010, 5'd3, `OPC_OP)};             // idx8: mulhsu
        dut.sram0.memory[5]  = {encode_shift64(6'b000000, 6'd32, 5'd20, 3'b001, 5'd20, `OPC_OP_IMM),    // idx11
                                 encode_i(-32'sd1, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM)};                   // idx10
        dut.sram0.memory[6]  = {encode_i(32'sd2, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM),                     // idx13
                                 encode_shift64(6'b000000, 6'd32, 5'd20, 3'b101, 5'd20, `OPC_OP_IMM)};   // idx12
        dut.sram0.memory[7]  = {encode_i(-32'sd100, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM),                  // idx15
                                 encode_r(7'b0000001, 5'd21, 5'd20, 3'b000, 5'd5, `OPC_OP_32)};          // idx14: mulw
        dut.sram0.memory[8]  = {encode_r(7'b0000001, 5'd21, 5'd20, 3'b100, 5'd6, `OPC_OP),              // idx17: div (PC 0x44)
                                 encode_i(32'sd7, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM)};                    // idx16
        dut.sram0.memory[9]  = {encode_i(32'sd3, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM),                     // idx19
                                 encode_i(-32'sd1, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM)};                   // idx18
        dut.sram0.memory[10] = {encode_i(-32'sd100, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM),                  // idx21
                                 encode_r(7'b0000001, 5'd21, 5'd20, 3'b101, 5'd7, `OPC_OP)};             // idx20: divu
        dut.sram0.memory[11] = {encode_r(7'b0000001, 5'd21, 5'd20, 3'b110, 5'd8, `OPC_OP),              // idx23: rem
                                 encode_i(32'sd7, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM)};                    // idx22
        dut.sram0.memory[12] = {encode_i(32'sd7, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM),                     // idx25
                                 encode_i(32'sd100, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM)};                  // idx24
        dut.sram0.memory[13] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM),                     // idx27
                                 encode_r(7'b0000001, 5'd21, 5'd20, 3'b111, 5'd9, `OPC_OP)};             // idx26: remu
        dut.sram0.memory[14] = {encode_i(32'sd2, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM),                     // idx29
                                 encode_shift64(6'b000000, 6'd31, 5'd20, 3'b001, 5'd20, `OPC_OP_IMM)};   // idx28
        dut.sram0.memory[15] = {encode_i(-32'sd1, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM),                    // idx31
                                 encode_r(7'b0000001, 5'd21, 5'd20, 3'b100, 5'd10, `OPC_OP_32)};         // idx30: divw
        dut.sram0.memory[16] = {encode_shift64(6'b000000, 6'd32, 5'd20, 3'b101, 5'd20, `OPC_OP_IMM),    // idx33
                                 encode_shift64(6'b000000, 6'd32, 5'd20, 3'b001, 5'd20, `OPC_OP_IMM)};   // idx32
        dut.sram0.memory[17] = {encode_r(7'b0000001, 5'd21, 5'd20, 3'b101, 5'd11, `OPC_OP_32),          // idx35: divuw
                                 encode_i(32'sd3, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM)};                    // idx34
        dut.sram0.memory[18] = {encode_shift64(6'b000000, 6'd31, 5'd20, 3'b001, 5'd20, `OPC_OP_IMM),    // idx37
                                 encode_i(32'sd1, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM)};                    // idx36
        dut.sram0.memory[19] = {encode_i(32'sd2, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM),                     // idx39
                                 encode_i(32'sd5, 5'd20, 3'b000, 5'd20, `OPC_OP_IMM)};                   // idx38
        dut.sram0.memory[20] = {encode_i(-32'sd1, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM),                    // idx41
                                 encode_r(7'b0000001, 5'd21, 5'd20, 3'b110, 5'd12, `OPC_OP_32)};         // idx40: remw
        dut.sram0.memory[21] = {encode_shift64(6'b000000, 6'd32, 5'd20, 3'b101, 5'd20, `OPC_OP_IMM),    // idx43
                                 encode_shift64(6'b000000, 6'd32, 5'd20, 3'b001, 5'd20, `OPC_OP_IMM)};   // idx42
        dut.sram0.memory[22] = {encode_i(32'sd3, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM),                     // idx45
                                 encode_i(-32'sd1, 5'd20, 3'b000, 5'd20, `OPC_OP_IMM)};                  // idx44
        dut.sram0.memory[23] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                                      // idx47: ebreak
                                 encode_r(7'b0000001, 5'd21, 5'd20, 3'b111, 5'd13, `OPC_OP_32)};         // idx46: remuw

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "dut.core0.halted never went high");

        check("MUL",    dut.core0.regfile0.gp_registers[1],  64'hFFFFFFFFFFFFFFFE);
        check("MULH",   dut.core0.regfile0.gp_registers[2],  64'hFFFFFFFFFFFFFFFF);
        check("MULHSU", dut.core0.regfile0.gp_registers[3],  64'hFFFFFFFFFFFFFFFF);
        check("MULHU",  dut.core0.regfile0.gp_registers[4],  64'hFFFFFFFFFFFFFFFE);
        check("MULW",   dut.core0.regfile0.gp_registers[5],  64'hFFFFFFFFFFFFFFFE);
        check("DIV",    dut.core0.regfile0.gp_registers[6],  -64'sd14);
        check("DIVU",   dut.core0.regfile0.gp_registers[7],  64'h5555555555555555);
        check("REM",    dut.core0.regfile0.gp_registers[8],  -64'sd2);
        check("REMU",   dut.core0.regfile0.gp_registers[9],  64'd2);
        check("DIVW",   dut.core0.regfile0.gp_registers[10], 64'hFFFFFFFFC0000000);
        check("DIVUW",  dut.core0.regfile0.gp_registers[11], 64'h0000000055555555);
        check("REMW",   dut.core0.regfile0.gp_registers[12], 64'hFFFFFFFFFFFFFFFF);
        check("REMUW",  dut.core0.regfile0.gp_registers[13], 64'd2);
        check("core halted (ebreak reached)", {63'b0, dut.core0.halted}, 64'd1);

        check("DIV genuinely held S_EXEC for many cycles (real multi-cycle divide, not combinational)",
              {56'b0, (div_exec_cycle_count_final > 8'd8) ? 8'd1 : 8'd0}, 64'd1);
        $display("(diagnostic, not a pass/fail check) DIV instruction held S_EXEC for %0d cycles", div_exec_cycle_count_final);

        $display("");
        $display("core_m_ext_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_m_ext_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
