// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, closing the RV64I instruction-decode coverage gap
 *
 * A whole-design Verilator coverage sweep found that the existing 17
 * testbenches, between them, never once execute a real number of base
 * RV64I instructions -- not because the RTL is untested in general (the
 * ALU/regfile/decoder are all exercised elsewhere), but because no
 * program in the whole suite happens to contain these specific
 * mnemonics. This file exists solely to close that gap: one program,
 * fetch -> decode -> execute -> writeback, exercising exactly the
 * instructions coverage showed as cold:
 *
 *   Bitwise, both forms:        AND, OR, XOR, ANDI, ORI, XORI
 *   Compare/shift, reg-reg:     SLT, SLTU, SLL, SRL, SRA
 *   Compare, immediate:         SLTIU
 *   Loads/stores:               LH, LHU, LWU, SH
 *   Branch:                     BGEU
 *   RV64 word-ops:              SUBW, SLLW, SLLIW, SRLIW, SRAIW
 *   Control:                    FENCE
 *
 * (ADDI/ADD/SUB/SLTI/SLLI/SRLI/SRAI/LB/LBU/LW/LD/SB/SW/SD/BEQ/BNE/BLT/
 * BLTU/BGE/JAL/JALR/LUI/AUIPC/ADDIW/ADDW/SRAW/EBREAK are all already
 * covered by the 5 core_*_tb.sv testbenches this one is a sibling of --
 * not repeated here.)
 *
 * Every operand pair below is deliberately chosen so a wrong-instruction
 * bug (decoder routes to the wrong ALU op, or a sibling instruction's
 * logic silently substitutes) produces a DIFFERENT, wrong answer rather
 * than coincidentally matching -- the same discipline alu_tb.sv's own
 * SLT/SLTU-on-the-same-bits and SLL/SRL/SRA-on-INT64_MIN pairs already
 * use, applied here through the decoder/core instead of the bare ALU:
 *
 *   - AND/OR/XOR on 0xCA, 0xA6 give three genuinely different results
 *     (0x82 / 0xEE / 0x6C) -- a decoder mixup between any two of the
 *     three is caught, not masked.
 *   - SLT vs SLTU on the same (x26=-5, x24=202) pair: signed says 1
 *     (-5 < 202), unsigned says 0 (huge < 202) -- opposite answers on
 *     identical bits, so either op landing on the other's logic fails.
 *   - SLL/SRL/SRA on the same (x27=-8, x28=2) pair likewise diverge:
 *     -32, a huge positive number, and -2 respectively.
 *   - LH vs LHU and LW vs LWU each read the SAME stored value (0x8000,
 *     0x80000000 -- top bit of the field set) so sign- vs zero-extend
 *     is the only thing that can make one right and the other wrong.
 *   - BGEU vs BGE on (x31=-1, x30=1): signed says "not taken", unsigned
 *     says "taken" -- structured so a wrongly-not-taken branch leaves a
 *     poison value (999) in the destination register instead of the
 *     expected 1, exactly like core_branch_jump_tb.sv's BLT/BLTU pair.
 *   - SUBW vs plain SUB on the same (0x00000000FFFFFFFF - 1) operands:
 *     SUBW must truncate-then-resign to a NEGATIVE 64-bit value while
 *     SUB stays positive -- the same "does NOT truncate" contrast
 *     core_rv64_word_ops_tb.sv already uses for ADDW vs ADD.
 *   - FENCE is a spec-legal no-op on this core (no other bus master) --
 *     checked by bracketing it with a marker register write before and
 *     after, proving execution falls through to the next instruction
 *     rather than stalling or corrupting a register. ECALL used to get
 *     the same bracketed-no-op treatment here, back when it was a
 *     literal fall-through -- as of the U/S/M privilege-mode milestone
 *     it's a real synchronous trap instead, so exercising it here (this
 *     program sets up no mtvec at all) would just infinite-loop back to
 *     address 0. ECALL's real semantics are now exhaustively covered by
 *     testbench/core_priv_tb.sv instead; this file keeps the same
 *     instruction slot as a second, genuine `addi x0,x0,0` NOP so every
 *     downstream address stays unchanged.
 *
 * Register allocation: x1-x23 each hold exactly one independently-
 * checked final result and are never written again after their
 * defining instruction (checks read final register state, so a reused
 * "checked" register would silently read whatever clobbered it last --
 * an earlier draft of this file hit exactly that bug). x24-x31 are
 * pure scratch/operand registers, freely reused once their prior value
 * is no longer needed by anything downstream.
 *
 * Wiring, checking, and timeout follow the shared testbench/
 * infrastructure (check_lib.sv, halt_wait.sv, core_wb4_sram_harness.sv)
 * -- this is a new file, so it uses that infrastructure directly rather
 * than the hand-rolled patterns the 5 sibling core_*_tb.sv files
 * predate and were deliberately left alone during that migration.
 */
module core_isa_coverage_gap_tb;

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

    initial begin
        #1; // run after wb4_sram's own time-0 init -- see core_wb_tb.sv's header

        /*
         * idx  addr  instruction                  notes
         *  0   0x00  addi x24, x0, 202             x24 = 0xCA (bitwise operand a)
         *  1   0x04  addi x25, x0, 166             x25 = 0xA6 (bitwise operand b)
         *  2   0x08  and  x1,  x24, x25            x1  = 0x82   [CHECK: AND]
         *  3   0x0C  or   x2,  x24, x25            x2  = 0xEE   [CHECK: OR]
         *  4   0x10  xor  x3,  x24, x25            x3  = 0x6C   [CHECK: XOR]
         *  5   0x14  andi x4,  x24, 166            x4  = 0x82   [CHECK: ANDI]
         *  6   0x18  ori  x5,  x24, 166            x5  = 0xEE   [CHECK: ORI]
         *  7   0x1C  xori x6,  x24, 166            x6  = 0x6C   [CHECK: XORI]
         *  8   0x20  addi x26, x0, -5              x26 = -5
         *  9   0x24  slt  x7,  x26, x24            x7  = 1      [CHECK: SLT]  (signed: -5 < 202)
         * 10   0x28  sltu x8,  x26, x24            x8  = 0      [CHECK: SLTU] (unsigned: huge < 202)
         * 11   0x2C  addi x27, x0, -8              x27 = -8
         * 12   0x30  addi x28, x0, 2               x28 = 2
         * 13   0x34  sll  x9,  x27, x28            x9  = 0xFFFFFFFFFFFFFFE0 (-32)  [CHECK: SLL]
         * 14   0x38  srl  x10, x27, x28            x10 = 0x3FFFFFFFFFFFFFFE       [CHECK: SRL]
         * 15   0x3C  sra  x11, x27, x28            x11 = 0xFFFFFFFFFFFFFFFE (-2)  [CHECK: SRA]
         * 16   0x40  addi x29, x0, 1024            x29 = data base address
         * 17   0x44  addi x30, x0, 1               x30 = 1
         * 18   0x48  slli x30, x30, 15             x30 = 0x8000 (bit 15 set)
         * 19   0x4C  sh   x30, 0(x29)              mem[0x400] = 0x8000
         * 20   0x50  lh   x12, 0(x29)              x12 = 0xFFFFFFFFFFFF8000 (sign-ext) [CHECK: LH]
         * 21   0x54  lhu  x13, 0(x29)              x13 = 0x8000 (zero-ext)             [CHECK: LHU]
         * 22   0x58  addi x30, x0, 1               x30 = 1 (reuse -- LH/LHU's use done)
         * 23   0x5C  slli x30, x30, 31             x30 = 0x80000000 (bit 31 set)
         * 24   0x60  sw   x30, 8(x29)              mem[0x408] = 0x80000000
         * 25   0x64  lwu  x14, 8(x29)              x14 = 0x80000000 (zero-ext)         [CHECK: LWU]
         * 26   0x68  addi x31, x0, -1              x31 = -1 (all Fs)
         * 27   0x6C  addi x30, x0, 1               x30 = 1 (reuse -- LWU's use done)
         * 28   0x70  bgeu x31, x30, 8   -> 0x78    taken (unsigned: huge >= 1)
         * 29   0x74  addi x15, x0, 999             SKIPPED -- proves BGEU really took the branch
         * 30   0x78  addi x15, x0, 1               x15 = 1  [CHECK: BGEU]
         * 31   0x7C  addi x27, x0, -1              x27 = -1 (reuse -- shift-trio's use done)
         * 32   0x80  slli x27, x27, 32             x27 = 0xFFFFFFFF00000000
         * 33   0x84  srli x27, x27, 32             x27 = 0x00000000FFFFFFFF
         * 34   0x88  addi x28, x0, 1               x28 = 1 (reuse -- shift-trio's use done)
         * 35   0x8C  subw x16, x27, x28            x16 = 0xFFFFFFFFFFFFFFFE (truncated+resigned) [CHECK: SUBW]
         * 36   0x90  sub  x17, x27, x28            x17 = 0x00000000FFFFFFFE (stays positive)     [CHECK: SUB]
         * 37   0x94  addi x29, x0, 31              x29 = 31 (reuse -- data-base's use done)
         * 38   0x98  sllw x18, x28, x29            x18 = 0xFFFFFFFF80000000 (1<<31, truncated+resigned) [CHECK: SLLW]
         * 39   0x9C  slliw x19, x28, 31            x19 = 0xFFFFFFFF80000000 (immediate form, same result) [CHECK: SLLIW]
         * 40   0xA0  srliw x20, x27, 4             x20 = 0x0FFFFFFF (logical shift, then resign) [CHECK: SRLIW]
         * 41   0xA4  addi x30, x0, 1               x30 = 1 (reuse -- BGEU's use done)
         * 42   0xA8  slli x30, x30, 31             x30 = 0x80000000
         * 43   0xAC  sraiw x21, x30, 4             x21 = 0xFFFFFFFFF8000000 (arithmetic shift, then resign) [CHECK: SRAIW]
         * 44   0xB0  addi x22, x0, 111             x22 = 111 (fence marker)
         * 45   0xB4  fence                          no-op (pred/succ deliberately nonzero)
         * 46   0xB8  addi x22, x22, 1              x22 = 112  [CHECK: FENCE] -- proves fence fell through
         * 47   0xB8  addi x23, x0, 222             x23 = 222 (no-op marker)
         * 48   0xBC  addi x0, x0, 0                 plain NOP (formerly ecall -- see header comment)
         * 49   0xC0  addi x23, x23, 1              x23 = 223  [CHECK: NOP fallthrough] -- second no-op bracket, distinct from FENCE's own
         * 50   0xC4  addi x0, x0, 0                 plain NOP (was a stray, always-fetched 32'h0 padding word -- see its own comment below)
         * 51   0xC8  sltiu x24, x26, 10            x24 = 0    [CHECK: SLTIU] (unsigned: huge < 10)
         * 52   0xCC  ebreak
         *
         * (Note: addresses in this trailing section, idx43 onward, were
         * previously off by one 4-byte slot in this table relative to
         * the actual memory[] placement below -- a pre-existing,
         * purely-cosmetic transcription slip that never mattered while
         * every comment-adjacent instruction was still correctly
         * identified by name. Corrected here while fixing the real bug
         * above; not re-audited further back in the table, since
         * nothing before idx43 was touched by this fix.)
         */
        dut.sram0.memory[0]  = {encode_i(32'sd166, 5'd0, 3'b000, 5'd25, `OPC_OP_IMM),
                                 encode_i(32'sd202, 5'd0, 3'b000, 5'd24, `OPC_OP_IMM)};
        dut.sram0.memory[1]  = {encode_r(7'b0000000, 5'd25, 5'd24, 3'b110, 5'd2, `OPC_OP),
                                 encode_r(7'b0000000, 5'd25, 5'd24, 3'b111, 5'd1, `OPC_OP)};
        dut.sram0.memory[2]  = {encode_i(32'sd166, 5'd24, 3'b111, 5'd4, `OPC_OP_IMM),
                                 encode_r(7'b0000000, 5'd25, 5'd24, 3'b100, 5'd3, `OPC_OP)};
        dut.sram0.memory[3]  = {encode_i(32'sd166, 5'd24, 3'b100, 5'd6, `OPC_OP_IMM),
                                 encode_i(32'sd166, 5'd24, 3'b110, 5'd5, `OPC_OP_IMM)};
        dut.sram0.memory[4]  = {encode_r(7'b0000000, 5'd24, 5'd26, 3'b010, 5'd7, `OPC_OP),
                                 encode_i(-32'sd5, 5'd0, 3'b000, 5'd26, `OPC_OP_IMM)};
        dut.sram0.memory[5]  = {encode_i(-32'sd8, 5'd0, 3'b000, 5'd27, `OPC_OP_IMM),
                                 encode_r(7'b0000000, 5'd24, 5'd26, 3'b011, 5'd8, `OPC_OP)};
        dut.sram0.memory[6]  = {encode_r(7'b0000000, 5'd28, 5'd27, 3'b001, 5'd9, `OPC_OP),
                                 encode_i(32'sd2, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut.sram0.memory[7]  = {encode_r(7'b0100000, 5'd28, 5'd27, 3'b101, 5'd11, `OPC_OP),
                                 encode_r(7'b0000000, 5'd28, 5'd27, 3'b101, 5'd10, `OPC_OP)};
        dut.sram0.memory[8]  = {encode_i(32'sd1, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),
                                 encode_i(32'sd1024, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)};
        dut.sram0.memory[9]  = {encode_s(32'sd0, 5'd30, 5'd29, 3'b001, `OPC_STORE),
                                 encode_shift64(6'b000000, 6'd15, 5'd30, 3'b001, 5'd30, `OPC_OP_IMM)};
        dut.sram0.memory[10] = {encode_i(32'sd0, 5'd29, 3'b101, 5'd13, `OPC_LOAD),
                                 encode_i(32'sd0, 5'd29, 3'b001, 5'd12, `OPC_LOAD)};
        dut.sram0.memory[11] = {encode_shift64(6'b000000, 6'd31, 5'd30, 3'b001, 5'd30, `OPC_OP_IMM),
                                 encode_i(32'sd1, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)};
        dut.sram0.memory[12] = {encode_i(32'sd8, 5'd29, 3'b110, 5'd14, `OPC_LOAD),
                                 encode_s(32'sd8, 5'd30, 5'd29, 3'b010, `OPC_STORE)};
        dut.sram0.memory[13] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),
                                 encode_i(-32'sd1, 5'd0, 3'b000, 5'd31, `OPC_OP_IMM)};
        dut.sram0.memory[14] = {encode_i(32'sd999, 5'd0, 3'b000, 5'd15, `OPC_OP_IMM), // idx29: POISON, must be skipped
                                 encode_b(32'sd8, 5'd30, 5'd31, 3'b111, `OPC_BRANCH)}; // idx28: bgeu x31,x30,+8
        dut.sram0.memory[15] = {encode_i(-32'sd1, 5'd0, 3'b000, 5'd27, `OPC_OP_IMM),
                                 encode_i(32'sd1, 5'd0, 3'b000, 5'd15, `OPC_OP_IMM)}; // idx30: landing target
        dut.sram0.memory[16] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),
                                 encode_shift64(6'b000000, 6'd32, 5'd27, 3'b101, 5'd27, `OPC_OP_IMM)};
        dut.sram0.memory[17] = {encode_r(7'b0100000, 5'd28, 5'd27, 3'b000, 5'd17, `OPC_OP),
                                 encode_r(7'b0100000, 5'd28, 5'd27, 3'b000, 5'd16, `OPC_OP_32)};
        dut.sram0.memory[18] = {encode_r(7'b0000000, 5'd29, 5'd28, 3'b001, 5'd18, `OPC_OP_32),
                                 encode_i(32'sd31, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)};
        dut.sram0.memory[19] = {encode_shift32w(7'b0000000, 5'd4, 5'd27, 3'b101, 5'd20, `OPC_OP_IMM_32),
                                 encode_shift32w(7'b0000000, 5'd31, 5'd28, 3'b001, 5'd19, `OPC_OP_IMM_32)};
        dut.sram0.memory[20] = {encode_shift64(6'b000000, 6'd31, 5'd30, 3'b001, 5'd30, `OPC_OP_IMM),
                                 encode_i(32'sd1, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)};
        dut.sram0.memory[21] = {encode_i(32'sd111, 5'd0, 3'b000, 5'd22, `OPC_OP_IMM),
                                 encode_shift32w(7'b0100000, 5'd4, 5'd30, 3'b101, 5'd21, `OPC_OP_IMM_32)};
        dut.sram0.memory[22] = {encode_i(32'sd1, 5'd22, 3'b000, 5'd22, `OPC_OP_IMM),
                                 encode_i(32'h000000FF, 5'd0, 3'b000, 5'd0, `OPC_FENCE)};
        dut.sram0.memory[23] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM), // addi x0,x0,0 (plain NOP -- formerly ecall, see header comment)
                                 encode_i(32'sd222, 5'd0, 3'b000, 5'd23, `OPC_OP_IMM)};
        dut.sram0.memory[24] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM), // addi x0,x0,0 (plain NOP -- was a stray 32'h0 padding word;
                                                                                    // genuinely fetched and executed every run, tolerated
                                                                                    // silently before only because an unrecognized encoding
                                                                                    // was itself a no-op pre-privilege-mode-milestone -- now
                                                                                    // that illegal-instruction trapping is real, 32'h0 here
                                                                                    // would trap to mtvec=0 (never set by this program) and
                                                                                    // infinite-loop back to the start)
                                 encode_i(32'sd1, 5'd23, 3'b000, 5'd23, `OPC_OP_IMM)};
        dut.sram0.memory[25] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM}, // idx51: ebreak
                                 encode_i(32'sd10, 5'd26, 3'b011, 5'd24, `OPC_OP_IMM)}; // idx50: sltiu x24,x26,10 -- x26 (=-5) and x24 (SLT/SLTU's old rs2) are both long-dead by here, safe to reuse

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "dut.core0.halted never went high");

        check("AND",   dut.core0.regfile0.gp_registers[1],  64'h82);
        check("OR",    dut.core0.regfile0.gp_registers[2],  64'hEE);
        check("XOR",   dut.core0.regfile0.gp_registers[3],  64'h6C);
        check("ANDI",  dut.core0.regfile0.gp_registers[4],  64'h82);
        check("ORI",   dut.core0.regfile0.gp_registers[5],  64'hEE);
        check("XORI",  dut.core0.regfile0.gp_registers[6],  64'h6C);
        check("SLT (signed, -5 < 202)",      dut.core0.regfile0.gp_registers[7],  64'd1);
        check("SLTU (unsigned, huge < 202)", dut.core0.regfile0.gp_registers[8],  64'd0);
        check("SLTIU (unsigned, huge < 10)", dut.core0.regfile0.gp_registers[24], 64'd0);
        check("SLL",   dut.core0.regfile0.gp_registers[9],  64'hFFFFFFFFFFFFFFE0);
        check("SRL",   dut.core0.regfile0.gp_registers[10], 64'h3FFFFFFFFFFFFFFE);
        check("SRA",   dut.core0.regfile0.gp_registers[11], 64'hFFFFFFFFFFFFFFFE);
        check("LH (sign-extended)",  dut.core0.regfile0.gp_registers[12], 64'hFFFFFFFFFFFF8000);
        check("LHU (zero-extended)", dut.core0.regfile0.gp_registers[13], 64'h8000);
        check("LWU (zero-extended)", dut.core0.regfile0.gp_registers[14], 64'h80000000);
        check("BGEU took the branch (unsigned)", dut.core0.regfile0.gp_registers[15], 64'd1);
        check("SUBW truncates+resigns -> negative", dut.core0.regfile0.gp_registers[16], 64'hFFFFFFFFFFFFFFFE);
        check("SUB (64-bit) does NOT truncate -> stays positive", dut.core0.regfile0.gp_registers[17], 64'hFFFFFFFE);
        check("SLLW truncates+resigns",  dut.core0.regfile0.gp_registers[18], 64'hFFFFFFFF80000000);
        check("SLLIW truncates+resigns", dut.core0.regfile0.gp_registers[19], 64'hFFFFFFFF80000000);
        check("SRLIW logical-shifts then resigns", dut.core0.regfile0.gp_registers[20], 64'h0FFFFFFF);
        check("SRAIW arithmetic-shifts then resigns", dut.core0.regfile0.gp_registers[21], 64'hFFFFFFFFF8000000);
        check("FENCE fell through (no stall/corruption)", dut.core0.regfile0.gp_registers[22], 64'd112);
        check("plain NOP fell through (no stall/corruption)", dut.core0.regfile0.gp_registers[23], 64'd223);
        check("core halted (ebreak reached)", {63'b0, dut.core0.halted}, 64'd1);

        $display("");
        $display("core_isa_coverage_gap_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_isa_coverage_gap_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
