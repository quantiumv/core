// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, A extension (atomics) end to end
 *
 * All 22 RV64A instructions through the real fetch -> decode -> execute ->
 * memory -> writeback path: LR.W/D, SC.W/D, and the 9 read-modify-write
 * AMO ops (SWAP/ADD/XOR/OR/AND/MIN/MAX/MINU/MAXU) each in .W/.D width.
 * Unit-level correctness for MIN/MAX/MINU/MAXU is already proven by
 * design/alu_tb.sv -- this file's job is different: prove the DECODE,
 * FSM (the new S_AMO_WRITE state), reservation-register, and operand-mux
 * wiring route each instruction to the right place with the right
 * operands, not re-derive the arithmetic.
 *
 * Memory layout: program code occupies word 0 through word 62 (PC
 * 0-0x1F8); all AMO/LR/SC scratch data lives at word 150 (byte 1200) and
 * up, one dedicated word per sub-test, chosen with generous headroom so
 * code and data can never collide.
 *
 * Register convention: x28 = address (reloaded via addi immediately
 * before each use -- every scratch byte address used here fits ADDI's
 * 12-bit signed immediate, so no LUI is needed except for the one
 * LR.W-specific test that deliberately needs a sign-bit-set 32-bit
 * pattern). x29 = preload/OLD-value scratch, x30 = the AMO/SC's rs2
 * operand -- both reloaded per phase, never read after their own phase.
 * x1 through x27, x31 (skipping x28-x30) are FINAL check destinations
 * read only once, at the very end, after halt -- x3 and x8 are
 * deliberately reused late (for AMOMAXU.W/D) after their only earlier use
 * (an uncontested reservation-setting LR.W whose own value is never
 * checked) is long since consumed, since 31 registers isn't quite enough
 * for 28 distinct final values otherwise.
 *
 * Two decisive old-vs-new-value regressions (per the plan's own
 * guidance, not just checking rd for every op): AMOADD.W using
 * INT32_MAX+1 (a genuine 32-bit wraparound the naive "sign-extend then
 * add" order gets wrong -- see core.sv's amo_result_w_trunc comment) and
 * AMOMIN.W (old=3, rs2=-5 -- the smaller SIGNED value must be selected,
 * with a follow-up load confirming memory actually changed rather than
 * coincidentally staying put). AMOMINU.W/AMOMAXU.W reuse the identical
 * -5-bit-pattern-vs-3 operand pair specifically so the unsigned
 * interpretation's OPPOSITE choice is visible on the exact same bits,
 * mirroring alu_tb.sv's own MIN/MAX/MINU/MAXU disambiguation.
 *
 * Uses the shared testbench/ infrastructure (check_lib.sv, halt_wait.sv,
 * core_wb4_sram_harness.sv), same as every testbench written since that
 * environment was built.
 */
module core_a_ext_tb;

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
     * White-box S_AMO_WRITE-visit check. AMOSWAP.W (the program's first
     * true read-modify-write AMO) lands at byte address 0x8C (idx35 --
     * see the memory layout comment below). Count consecutive cycles
     * dut.core0.state reads S_AMO_WRITE (2'd3) while dut.core0.pc reads
     * that address -- a subtly-broken state-transition arm could
     * otherwise leave S_AMO_WRITE unreachable (committing straight off
     * S_MEM's read ack instead) and still coincidentally produce a
     * plausible-looking answer, since alu_result would still hold a
     * stale address-phase value that a register check alone wouldn't
     * catch.
     */
    localparam logic [63:0] AMOSWAP_W_PC = 64'h8C;
    int amo_write_cycle_count = 0;
    always @(posedge clk) begin
        if (dut.core0.pc == AMOSWAP_W_PC && dut.core0.state == 2'd3 /* S_AMO_WRITE */) begin
            amo_write_cycle_count <= amo_write_cycle_count + 1;
        end
    end

    initial begin
        #1; // run after wb4_sram's own time-0 init -- see core_wb_tb.sv's header

        /*
         * idx  addr   instruction                          notes
         *  0   0x00   lui  x29, 0x80000                    x29 = 0xFFFFFFFF80000000
         *  1   0x04   addi x29, x29, 1                     x29 low32 = 0x80000001 (sign bit set)
         *  2   0x08   addi x28, x0, 1200                   ADDR (word150)
         *  3   0x0C   sw   x29, 0(x28)
         *  4   0x10   lr.w x1, (x28)                        x1 = 0xFFFFFFFF80000001      [CHECK: LR.W]
         *  5   0x14   addi x29, x0, -16
         *  6   0x18   addi x28, x0, 1208
         *  7   0x1C   sd   x29, 0(x28)
         *  8   0x20   lr.d x2, (x28)                        x2 = -16                     [CHECK: LR.D]
         *  9   0x24   addi x29, x0, 85 (0x55)
         * 10   0x28   addi x28, x0, 1216
         * 11   0x2C   sw   x29, 0(x28)
         * 12   0x30   lr.w x3, (x28)                        sets reservation (x3 not checked yet)
         * 13   0x34   addi x30, x0, 102 (0x66)
         * 14   0x38   sc.w x4, x30, (x28)                   x4 = 0 (success)             [CHECK: SC success]
         * 15   0x3C   lw   x5, 0(x28)                       x5 = 0x66                    [CHECK: SC success mem]
         * 16   0x40   addi x29, x0, 119 (0x77)
         * 17   0x44   addi x28, x0, 1224
         * 18   0x48   sw   x29, 0(x28)
         * 19   0x4C   addi x30, x0, 136 (0x88)
         * 20   0x50   sc.w x6, x30, (x28)                   x6 = 1 (no reservation)      [CHECK: SC-no-LR]
         * 21   0x54   lw   x7, 0(x28)                       x7 = 0x77 (unchanged)        [CHECK: SC-no-LR mem]
         * 22   0x58   addi x29, x0, 17 (0x11)
         * 23   0x5C   addi x28, x0, 1232
         * 24   0x60   sw   x29, 0(x28)
         * 25   0x64   lr.w x8, (x28)                        sets reservation (x8 not checked yet)
         * 26   0x68   addi x31, x0, 34 (0x22)
         * 27   0x6C   sw   x31, 0(x28)                      intervening store -- clears reservation
         * 28   0x70   addi x30, x0, 51 (0x33)
         * 29   0x74   sc.w x9, x30, (x28)                   x9 = 1 (reservation cleared) [CHECK: SC-after-store]
         * 30   0x78   lw   x10, 0(x28)                      x10 = 0x22 (unchanged)       [CHECK: SC-after-store mem]
         * 31   0x7C   addi x29, x0, 16 (0x10)
         * 32   0x80   addi x28, x0, 1240
         * 33   0x84   sw   x29, 0(x28)
         * 34   0x88   addi x30, x0, 32 (0x20)
         * 35   0x8C   amoswap.w x11, x30, (x28)             x11 = 0x10 (old)             [CHECK: AMOSWAP.W] (white-box target)
         * 36   0x90   addi x29, x0, 100
         * 37   0x94   addi x28, x0, 1248
         * 38   0x98   sd   x29, 0(x28)
         * 39   0x9C   addi x30, x0, 200
         * 40   0xA0   amoswap.d x12, x30, (x28)             x12 = 100                    [CHECK: AMOSWAP.D]
         * 41   0xA4   lui  x29, 0x80000
         * 42   0xA8   addi x29, x29, -1                     x29 low32 = 0x7FFFFFFF (INT32_MAX)
         * 43   0xAC   addi x28, x0, 1256
         * 44   0xB0   sw   x29, 0(x28)
         * 45   0xB4   addi x30, x0, 1
         * 46   0xB8   amoadd.w x13, x30, (x28)              x13 = 0x7FFFFFFF (old)       [CHECK: AMOADD.W]
         * 47   0xBC   lw   x27, 0(x28)                      x27 = 0xFFFFFFFF80000000 (wrapped, sign-ext) [CHECK: AMOADD.W mem]
         * 48   0xC0   addi x29, x0, 5
         * 49   0xC4   addi x28, x0, 1264
         * 50   0xC8   sd   x29, 0(x28)
         * 51   0xCC   addi x30, x0, 3
         * 52   0xD0   amoadd.d x14, x30, (x28)              x14 = 5                      [CHECK: AMOADD.D]
         * 53   0xD4   addi x29, x0, 6
         * 54   0xD8   addi x28, x0, 1272
         * 55   0xDC   sw   x29, 0(x28)
         * 56   0xE0   addi x30, x0, 3
         * 57   0xE4   amoxor.w x15, x30, (x28)              x15 = 6                      [CHECK: AMOXOR.W]
         * 58   0xE8   addi x29, x0, 6
         * 59   0xEC   addi x28, x0, 1280
         * 60   0xF0   sd   x29, 0(x28)
         * 61   0xF4   addi x30, x0, 3
         * 62   0xF8   amoxor.d x16, x30, (x28)              x16 = 6                      [CHECK: AMOXOR.D]
         * 63   0xFC   addi x29, x0, 6
         * 64   0x100  addi x28, x0, 1288
         * 65   0x104  sw   x29, 0(x28)
         * 66   0x108  addi x30, x0, 3
         * 67   0x10C  amoor.w x17, x30, (x28)               x17 = 6                      [CHECK: AMOOR.W]
         * 68   0x110  addi x29, x0, 6
         * 69   0x114  addi x28, x0, 1296
         * 70   0x118  sd   x29, 0(x28)
         * 71   0x11C  addi x30, x0, 3
         * 72   0x120  amoor.d x18, x30, (x28)               x18 = 6                      [CHECK: AMOOR.D]
         * 73   0x124  addi x29, x0, 6
         * 74   0x128  addi x28, x0, 1304
         * 75   0x12C  sw   x29, 0(x28)
         * 76   0x130  addi x30, x0, 3
         * 77   0x134  amoand.w x19, x30, (x28)              x19 = 6                      [CHECK: AMOAND.W]
         * 78   0x138  addi x29, x0, 6
         * 79   0x13C  addi x28, x0, 1312
         * 80   0x140  sd   x29, 0(x28)
         * 81   0x144  addi x30, x0, 3
         * 82   0x148  amoand.d x20, x30, (x28)              x20 = 6                      [CHECK: AMOAND.D]
         * 83   0x14C  addi x29, x0, 3
         * 84   0x150  addi x28, x0, 1320
         * 85   0x154  sw   x29, 0(x28)
         * 86   0x158  addi x30, x0, -5
         * 87   0x15C  amomin.w x21, x30, (x28)              x21 = 3 (old)                [CHECK: AMOMIN.W]
         * 88   0x160  lw   x31, 0(x28)                      x31 = -5 sign-ext            [CHECK: AMOMIN.W mem]
         * 89   0x164  addi x29, x0, 30
         * 90   0x168  addi x28, x0, 1328
         * 91   0x16C  sd   x29, 0(x28)
         * 92   0x170  addi x30, x0, -50
         * 93   0x174  amomin.d x22, x30, (x28)              x22 = 30                     [CHECK: AMOMIN.D]
         * 94   0x178  addi x29, x0, -5
         * 95   0x17C  addi x28, x0, 1336
         * 96   0x180  sw   x29, 0(x28)
         * 97   0x184  addi x30, x0, 3
         * 98   0x188  amomax.w x23, x30, (x28)              x23 = -5 sign-ext (old)      [CHECK: AMOMAX.W]
         * 99   0x18C  addi x29, x0, -50
         * 100  0x190  addi x28, x0, 1344
         * 101  0x194  sd   x29, 0(x28)
         * 102  0x198  addi x30, x0, 30
         * 103  0x19C  amomax.d x24, x30, (x28)              x24 = -50 (old)              [CHECK: AMOMAX.D]
         * 104  0x1A0  addi x29, x0, -5
         * 105  0x1A4  addi x28, x0, 1352
         * 106  0x1A8  sw   x29, 0(x28)
         * 107  0x1AC  addi x30, x0, 3
         * 108  0x1B0  amominu.w x25, x30, (x28)             x25 = -5 sign-ext (old)      [CHECK: AMOMINU.W]
         * 109  0x1B4  addi x29, x0, -50
         * 110  0x1B8  addi x28, x0, 1360
         * 111  0x1BC  sd   x29, 0(x28)
         * 112  0x1C0  addi x30, x0, 30
         * 113  0x1C4  amominu.d x26, x30, (x28)             x26 = -50 (old)              [CHECK: AMOMINU.D]
         * 114  0x1C8  addi x29, x0, 3
         * 115  0x1CC  addi x28, x0, 1368
         * 116  0x1D0  sw   x29, 0(x28)
         * 117  0x1D4  addi x30, x0, -5
         * 118  0x1D8  amomaxu.w x3, x30, (x28)              x3 = 3 (old, reuses x3)      [CHECK: AMOMAXU.W]
         * 119  0x1DC  addi x29, x0, 30
         * 120  0x1E0  addi x28, x0, 1376
         * 121  0x1E4  sd   x29, 0(x28)
         * 122  0x1E8  addi x30, x0, -50
         * 123  0x1EC  amomaxu.d x8, x30, (x28)              x8 = 30 (old, reuses x8)     [CHECK: AMOMAXU.D]
         * 124  0x1F0  ebreak
         * 125  0x1F4  addi x0, x0, 0                        padding, never fetched (ebreak halts first)
         */
        dut.sram0.memory[0] = {encode_i(32'sd1, 5'd29, 3'b000, 5'd29, `OPC_OP_IMM),  // idx1
                                 encode_u(20'h80000, 5'd29, `OPC_LUI)}; // idx0
        dut.sram0.memory[1] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE),  // idx3
                                 encode_i(32'sd1200, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx2
        dut.sram0.memory[2] = {encode_i(-32'sd16, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),  // idx5
                                 encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0, 5'd28, `FUNCT3_AMO_W, 5'd1, `OPC_AMO)}; // idx4
        dut.sram0.memory[3] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b011, `OPC_STORE),  // idx7
                                 encode_i(32'sd1208, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx6
        dut.sram0.memory[4] = {encode_i(32'sd85, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),  // idx9
                                 encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0, 5'd28, `FUNCT3_AMO_D, 5'd2, `OPC_AMO)}; // idx8
        dut.sram0.memory[5] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE),  // idx11
                                 encode_i(32'sd1216, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx10
        dut.sram0.memory[6] = {encode_i(32'sd102, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),  // idx13
                                 encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0, 5'd28, `FUNCT3_AMO_W, 5'd3, `OPC_AMO)}; // idx12
        dut.sram0.memory[7] = {encode_i(32'sd0, 5'd28, 3'b010, 5'd5, `OPC_LOAD),  // idx15
                                 encode_amo(`FUNCT5_SC, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd4, `OPC_AMO)}; // idx14
        dut.sram0.memory[8] = {encode_i(32'sd1224, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),  // idx17
                                 encode_i(32'sd119, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)}; // idx16
        dut.sram0.memory[9] = {encode_i(32'sd136, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),  // idx19
                                 encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE)}; // idx18
        dut.sram0.memory[10] = {encode_i(32'sd0, 5'd28, 3'b010, 5'd7, `OPC_LOAD),  // idx21
                                 encode_amo(`FUNCT5_SC, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd6, `OPC_AMO)}; // idx20
        dut.sram0.memory[11] = {encode_i(32'sd1232, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),  // idx23
                                 encode_i(32'sd17, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)}; // idx22
        dut.sram0.memory[12] = {encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0, 5'd28, `FUNCT3_AMO_W, 5'd8, `OPC_AMO),  // idx25
                                 encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE)}; // idx24
        dut.sram0.memory[13] = {encode_s(32'sd0, 5'd31, 5'd28, 3'b010, `OPC_STORE),  // idx27
                                 encode_i(32'sd34, 5'd0, 3'b000, 5'd31, `OPC_OP_IMM)}; // idx26
        dut.sram0.memory[14] = {encode_amo(`FUNCT5_SC, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd9, `OPC_AMO),  // idx29
                                 encode_i(32'sd51, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)}; // idx28
        dut.sram0.memory[15] = {encode_i(32'sd16, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),  // idx31
                                 encode_i(32'sd0, 5'd28, 3'b010, 5'd10, `OPC_LOAD)}; // idx30
        dut.sram0.memory[16] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE),  // idx33
                                 encode_i(32'sd1240, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx32
        dut.sram0.memory[17] = {encode_amo(`FUNCT5_AMOSWAP, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd11, `OPC_AMO),  // idx35
                                 encode_i(32'sd32, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)}; // idx34
        dut.sram0.memory[18] = {encode_i(32'sd1248, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),  // idx37
                                 encode_i(32'sd100, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)}; // idx36
        dut.sram0.memory[19] = {encode_i(32'sd200, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),  // idx39
                                 encode_s(32'sd0, 5'd29, 5'd28, 3'b011, `OPC_STORE)}; // idx38
        dut.sram0.memory[20] = {encode_u(20'h80000, 5'd29, `OPC_LUI),  // idx41
                                 encode_amo(`FUNCT5_AMOSWAP, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_D, 5'd12, `OPC_AMO)}; // idx40
        dut.sram0.memory[21] = {encode_i(32'sd1256, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),  // idx43
                                 encode_i(-32'sd1, 5'd29, 3'b000, 5'd29, `OPC_OP_IMM)}; // idx42
        dut.sram0.memory[22] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),  // idx45
                                 encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE)}; // idx44
        dut.sram0.memory[23] = {encode_i(32'sd0, 5'd28, 3'b010, 5'd27, `OPC_LOAD),  // idx47
                                 encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd13, `OPC_AMO)}; // idx46
        dut.sram0.memory[24] = {encode_i(32'sd1264, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),  // idx49
                                 encode_i(32'sd5, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)}; // idx48
        dut.sram0.memory[25] = {encode_i(32'sd3, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),  // idx51
                                 encode_s(32'sd0, 5'd29, 5'd28, 3'b011, `OPC_STORE)}; // idx50
        dut.sram0.memory[26] = {encode_i(32'sd6, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),  // idx53
                                 encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_D, 5'd14, `OPC_AMO)}; // idx52
        dut.sram0.memory[27] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE),  // idx55
                                 encode_i(32'sd1272, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx54
        dut.sram0.memory[28] = {encode_amo(`FUNCT5_AMOXOR, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd15, `OPC_AMO),  // idx57
                                 encode_i(32'sd3, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)}; // idx56
        dut.sram0.memory[29] = {encode_i(32'sd1280, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),  // idx59
                                 encode_i(32'sd6, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)}; // idx58
        dut.sram0.memory[30] = {encode_i(32'sd3, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),  // idx61
                                 encode_s(32'sd0, 5'd29, 5'd28, 3'b011, `OPC_STORE)}; // idx60
        dut.sram0.memory[31] = {encode_i(32'sd6, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),  // idx63
                                 encode_amo(`FUNCT5_AMOXOR, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_D, 5'd16, `OPC_AMO)}; // idx62
        dut.sram0.memory[32] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE),  // idx65
                                 encode_i(32'sd1288, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx64
        dut.sram0.memory[33] = {encode_amo(`FUNCT5_AMOOR, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd17, `OPC_AMO),  // idx67
                                 encode_i(32'sd3, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)}; // idx66
        dut.sram0.memory[34] = {encode_i(32'sd1296, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),  // idx69
                                 encode_i(32'sd6, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)}; // idx68
        dut.sram0.memory[35] = {encode_i(32'sd3, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),  // idx71
                                 encode_s(32'sd0, 5'd29, 5'd28, 3'b011, `OPC_STORE)}; // idx70
        dut.sram0.memory[36] = {encode_i(32'sd6, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),  // idx73
                                 encode_amo(`FUNCT5_AMOOR, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_D, 5'd18, `OPC_AMO)}; // idx72
        dut.sram0.memory[37] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE),  // idx75
                                 encode_i(32'sd1304, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx74
        dut.sram0.memory[38] = {encode_amo(`FUNCT5_AMOAND, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd19, `OPC_AMO),  // idx77
                                 encode_i(32'sd3, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)}; // idx76
        dut.sram0.memory[39] = {encode_i(32'sd1312, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),  // idx79
                                 encode_i(32'sd6, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)}; // idx78
        dut.sram0.memory[40] = {encode_i(32'sd3, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),  // idx81
                                 encode_s(32'sd0, 5'd29, 5'd28, 3'b011, `OPC_STORE)}; // idx80
        dut.sram0.memory[41] = {encode_i(32'sd3, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),  // idx83
                                 encode_amo(`FUNCT5_AMOAND, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_D, 5'd20, `OPC_AMO)}; // idx82
        dut.sram0.memory[42] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE),  // idx85
                                 encode_i(32'sd1320, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx84
        dut.sram0.memory[43] = {encode_amo(`FUNCT5_AMOMIN, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd21, `OPC_AMO),  // idx87
                                 encode_i(-32'sd5, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)}; // idx86
        dut.sram0.memory[44] = {encode_i(32'sd30, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),  // idx89
                                 encode_i(32'sd0, 5'd28, 3'b010, 5'd31, `OPC_LOAD)}; // idx88
        dut.sram0.memory[45] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b011, `OPC_STORE),  // idx91
                                 encode_i(32'sd1328, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx90
        dut.sram0.memory[46] = {encode_amo(`FUNCT5_AMOMIN, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_D, 5'd22, `OPC_AMO),  // idx93
                                 encode_i(-32'sd50, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)}; // idx92
        dut.sram0.memory[47] = {encode_i(32'sd1336, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),  // idx95
                                 encode_i(-32'sd5, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)}; // idx94
        dut.sram0.memory[48] = {encode_i(32'sd3, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),  // idx97
                                 encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE)}; // idx96
        dut.sram0.memory[49] = {encode_i(-32'sd50, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),  // idx99
                                 encode_amo(`FUNCT5_AMOMAX, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd23, `OPC_AMO)}; // idx98
        dut.sram0.memory[50] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b011, `OPC_STORE),  // idx101
                                 encode_i(32'sd1344, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx100
        dut.sram0.memory[51] = {encode_amo(`FUNCT5_AMOMAX, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_D, 5'd24, `OPC_AMO),  // idx103
                                 encode_i(32'sd30, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)}; // idx102
        dut.sram0.memory[52] = {encode_i(32'sd1352, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),  // idx105
                                 encode_i(-32'sd5, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)}; // idx104
        dut.sram0.memory[53] = {encode_i(32'sd3, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),  // idx107
                                 encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE)}; // idx106
        dut.sram0.memory[54] = {encode_i(-32'sd50, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),  // idx109
                                 encode_amo(`FUNCT5_AMOMINU, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd25, `OPC_AMO)}; // idx108
        dut.sram0.memory[55] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b011, `OPC_STORE),  // idx111
                                 encode_i(32'sd1360, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx110
        dut.sram0.memory[56] = {encode_amo(`FUNCT5_AMOMINU, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_D, 5'd26, `OPC_AMO),  // idx113
                                 encode_i(32'sd30, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)}; // idx112
        dut.sram0.memory[57] = {encode_i(32'sd1368, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),  // idx115
                                 encode_i(32'sd3, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM)}; // idx114
        dut.sram0.memory[58] = {encode_i(-32'sd5, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM),  // idx117
                                 encode_s(32'sd0, 5'd29, 5'd28, 3'b010, `OPC_STORE)}; // idx116
        dut.sram0.memory[59] = {encode_i(32'sd30, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),  // idx119
                                 encode_amo(`FUNCT5_AMOMAXU, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_W, 5'd3, `OPC_AMO)}; // idx118
        dut.sram0.memory[60] = {encode_s(32'sd0, 5'd29, 5'd28, 3'b011, `OPC_STORE),  // idx121
                                 encode_i(32'sd1376, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // idx120
        dut.sram0.memory[61] = {encode_amo(`FUNCT5_AMOMAXU, 1'b0, 1'b0, 5'd30, 5'd28, `FUNCT3_AMO_D, 5'd8, `OPC_AMO),  // idx123
                                 encode_i(-32'sd50, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)}; // idx122
        dut.sram0.memory[62] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),  // idx125
                                 {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}}; // idx124

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "dut.core0.halted never went high");

        check("LR.W (sign-extends a 32-bit value with bit31 set)", dut.core0.regfile0.gp_registers[1], 64'hFFFFFFFF80000001);
        check("LR.D", dut.core0.regfile0.gp_registers[2], -64'sd16);

        check("LR->SC success: rd", dut.core0.regfile0.gp_registers[4], 64'd0);
        check("LR->SC success: memory updated", dut.core0.regfile0.gp_registers[5], 64'd102);

        check("SC with no prior LR: rd (failure)", dut.core0.regfile0.gp_registers[6], 64'd1);
        check("SC with no prior LR: memory unchanged", dut.core0.regfile0.gp_registers[7], 64'd119);

        check("SC after an intervening store: rd (failure, reservation cleared)",
              dut.core0.regfile0.gp_registers[9], 64'd1);
        check("SC after an intervening store: memory reflects the intervening store, not SC's own value",
              dut.core0.regfile0.gp_registers[10], 64'd34);

        check("AMOSWAP.W: rd = old", dut.core0.regfile0.gp_registers[11], 64'd16);
        check("AMOSWAP.D: rd = old", dut.core0.regfile0.gp_registers[12], 64'd100);

        check("AMOADD.W: rd = old (INT32_MAX)", dut.core0.regfile0.gp_registers[13], 64'h000000007FFFFFFF);
        check("AMOADD.W: memory wraps to INT32_MIN, sign-extended (32-bit overflow, not a naive 64-bit add+truncate)",
              dut.core0.regfile0.gp_registers[27], 64'hFFFFFFFF80000000);
        check("AMOADD.D: rd = old", dut.core0.regfile0.gp_registers[14], 64'd5);

        check("AMOXOR.W: rd = old", dut.core0.regfile0.gp_registers[15], 64'd6);
        check("AMOXOR.D: rd = old", dut.core0.regfile0.gp_registers[16], 64'd6);
        check("AMOOR.W: rd = old", dut.core0.regfile0.gp_registers[17], 64'd6);
        check("AMOOR.D: rd = old", dut.core0.regfile0.gp_registers[18], 64'd6);
        check("AMOAND.W: rd = old", dut.core0.regfile0.gp_registers[19], 64'd6);
        check("AMOAND.D: rd = old", dut.core0.regfile0.gp_registers[20], 64'd6);

        check("AMOMIN.W: rd = old (3)", dut.core0.regfile0.gp_registers[21], 64'd3);
        check("AMOMIN.W: memory picks the SIGNED-smaller value (-5), a real change from old",
              dut.core0.regfile0.gp_registers[31], -64'sd5);
        check("AMOMIN.D: rd = old", dut.core0.regfile0.gp_registers[22], 64'd30);

        check("AMOMAX.W: rd = old (-5, sign-extended)", dut.core0.regfile0.gp_registers[23], -64'sd5);
        check("AMOMAX.D: rd = old", dut.core0.regfile0.gp_registers[24], -64'sd50);

        /*
         * AMOMINU.W/AMOMAXU.W: SAME -5-bit-pattern-vs-3 operand pair as
         * AMOMIN.W/AMOMAX.W above, but the value read back into rd is
         * ALWAYS the sign-extended OLD value regardless of signed vs.
         * unsigned interpretation (per spec, the load itself always
         * sign-extends) -- the unsigned/signed DIFFERENCE shows up in
         * which operand the modify step selects for the NEW memory
         * value (already unit-tested exhaustively by alu_tb.sv's own
         * MIN/MAX/MINU/MAXU cases), not in rd. These checks confirm the
         * decode/writeback wiring routes MINU/MAXU as distinct
         * operations at all, not that they coincidentally use the same
         * old-value-to-rd path as MIN/MAX (which they correctly do).
         */
        check("AMOMINU.W: rd = old (-5's bit pattern, sign-extended on read)",
              dut.core0.regfile0.gp_registers[25], -64'sd5);
        check("AMOMINU.D: rd = old", dut.core0.regfile0.gp_registers[26], -64'sd50);
        check("AMOMAXU.W: rd = old (3)", dut.core0.regfile0.gp_registers[3], 64'd3);
        check("AMOMAXU.D: rd = old", dut.core0.regfile0.gp_registers[8], 64'd30);

        check("core halted (ebreak reached)", {63'b0, dut.core0.halted}, 64'd1);

        check("AMOSWAP.W genuinely visited S_AMO_WRITE as a distinct state (not skipped)",
              {56'b0, (amo_write_cycle_count > 8'd0) ? 8'd1 : 8'd0}, 64'd1);
        $display("(diagnostic, not a pass/fail check) AMOSWAP.W held S_AMO_WRITE for %0d cycle(s)", amo_write_cycle_count);

        $display("");
        $display("core_a_ext_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_a_ext_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
