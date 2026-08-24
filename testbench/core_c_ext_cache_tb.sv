// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core_c_ext_cache_tb -- core_c_ext_tb.sv's exact program,
 * routed through core_cache_harness.sv instead of core_wb4_sram_harness.sv
 *
 * Curated regression subset for the cache-hierarchy rollout (see the
 * session plan): a new file, not a mutation of the passing
 * core_c_ext_tb.sv (this project's own established convention -- see
 * e.g. soc_c_regression_tb.sv added alongside soc_tb.sv, not merged into
 * it). This specific program was picked first because it's the most
 * I$-relevant case in the existing suite: idx9's deliberately
 * dword-crossing fetch (pc=0x16) forces a genuine two-beat S_FETCH+
 * S_FETCH_HI sequence, exercising icache.sv's core-facing port across
 * two back-to-back requests for the SAME instruction in a way most other
 * directed tests never do. Now also exercises the D$ path for real
 * (idx18/idx19's C.SW/C.LW round trip goes through dcache0, not straight
 * to SRAM) -- originally landed pointed at core_icache_harness.sv (I$
 * only, D$ still direct-to-SRAM) as an earlier, narrower milestone; that
 * harness's own header documented it as temporary scaffolding superseded
 * once design/cache_complex.sv existed, which is exactly what re-pointing
 * this file here does, rather than leaving a second near-duplicate test
 * file behind.
 *
 * Every hierarchical reference below (dut.core0.*, dut.sram0.memory[])
 * is unchanged from the original -- core_cache_harness.sv deliberately
 * names its core/backing-SRAM instances core0/sram0, matching
 * core_wb4_sram_harness.sv exactly, so re-pointing a test is genuinely
 * just the one instantiation line. core.sv's own FSM/state semantics
 * (including the S_FETCH_HI white-box check below) are completely
 * unaffected by the cache splice, which only changes what answers the
 * memory side of the bus during S_FETCH/S_FETCH_HI/S_MEM/S_AMO_WRITE.
 */
module core_c_ext_cache_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_cache_harness #(.NUM_WORDS(128)) dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    logic halted = 1'b0;
    always @(posedge clk) if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"

    /*
     * White-box check: S_FETCH_HI (state 3'd4, the C extension's new
     * 5th state_t value) must genuinely be visited while fetching the
     * deliberately-crossing instruction at pc=0x16 -- mirrors
     * core_a_ext_tb.sv's own hand-rolled S_AMO_WRITE-visit check.
     */
    localparam logic [63:0] CROSSING_INSTR_PC = 64'h16;
    int fetch_hi_visit_count = 0;
    always @(posedge clk) begin
        if (dut.core0.pc == CROSSING_INSTR_PC && dut.core0.state == 3'd4) begin
            fetch_hi_visit_count <= fetch_hi_visit_count + 1;
        end
    end

    logic [15:0] hwq[$];

    task automatic push16(input logic [15:0] hw);
        hwq.push_back(hw);
    endtask

    task automatic push32(input logic [31:0] w);
        hwq.push_back(w[15:0]);
        hwq.push_back(w[31:16]);
    endtask

    initial begin
        #1; // run after wb4_sram's own time-0 init of crt0.hex

        /* idx0: addi x2,x0,256 -- x2=256 */
        push32(encode_i(256, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM));
        /* idx1: c.addi16sp nzimm=16 -- x2=272 */
        push16(encode_c_addi16sp(16));
        /* idx2: c.li x5,-5 -- x5=-5 (sign-extended) */
        push16(encode_c_li(-5, 5'd5));
        /* idx3: c.lui x6, nzimm6=5 -- x6=0x5000 */
        push16(encode_c_lui(6'b000101, 5'd6));
        /* idx4: addi x7,x0,100 -- x7=100 */
        push32(encode_i(100, 5'd0, 3'b000, 5'd7, `OPC_OP_IMM));
        /* idx5: c.mv x9,x7 -- x9=100 */
        push16(encode_c_mv(5'd9, 5'd7));
        /* idx6: c.li x10,7 -- x10=7 (temp; reused as a scratch address later) */
        push16(encode_c_li(7, 5'd10));
        /* idx7: c.add x9,x9,x10 -- x9=107 */
        push16(encode_c_add(5'd9, 5'd10));
        /* idx8: c.nop -- HINT, must be a genuine no-op */
        push16(encode_c_addi(0, 5'd0));
        /* idx9 (pc=0x16=22, dword-crossing): addi x12,x9,1 -- x12=108 */
        push32(encode_i(1, 5'd9, 3'b000, 5'd12, `OPC_OP_IMM));
        /* idx10: c.li x13,20 -- x13=20 (must survive the jump below untouched). */
        push16(encode_c_li(20, 5'd13));
        /* idx11: c.j +6 -- jumps clean over idx12's 4 bytes to idx13 */
        push16(encode_c_j(6));
        /* idx12 (POISON, must never execute): addi x13,x0,999 */
        push32(encode_i(999, 5'd0, 3'b000, 5'd13, `OPC_OP_IMM));
        /* idx13 (C.J's exact landing target): c.li x14,25 -- confirms landing
         * was exactly right, not off by any amount */
        push16(encode_c_li(25, 5'd14));
        /* idx14: addi x8,x0,111 -- x8=111 (x8 is creg field 0) */
        push32(encode_i(111, 5'd0, 3'b000, 5'd8, `OPC_OP_IMM));
        /* idx15: addi x11,x0,222 -- x11=222 (x11 is creg field 3) */
        push32(encode_i(222, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM));
        /* idx16: c.and x8,x8,x11 -- x8 = 111 & 222 = 78; x11 unchanged */
        push16(encode_c_ca(1'b0, `CA_FUNCT2_AND, 3'd0, 3'd3));
        /* idx17: addi x10,x0,800 -- x10=800 (scratch byte address, well past
         * this 60-byte program) */
        push32(encode_i(800, 5'd0, 3'b000, 5'd10, `OPC_OP_IMM));
        /* idx18: c.sw x8,0(x10) -- mem[800..803] = 78 */
        push16(encode_c_sw(7'd0, 3'd2, 3'd0));
        /* idx19: c.lw x15,0(x10) -- x15=78, confirms the store+load round trip */
        push16(encode_c_lw(7'd0, 3'd2, 3'd7));
        /* idx20: c.beqz x15,+20 -- x15=78!=0, must NOT branch */
        push16(encode_c_beqz(20, 3'd7));
        /* idx21: c.li x16,1 -- confirms the branch above fell through */
        push16(encode_c_li(1, 5'd16));
        /* idx22: c.ebreak -- halts the core */
        push16(`INSTR_C_EBREAK);

        for (int i = 0; i < hwq.size(); i = i + 4) begin
            dut.sram0.memory[i/4] = {
                (i+3 < hwq.size()) ? hwq[i+3] : 16'h0,
                (i+2 < hwq.size()) ? hwq[i+2] : 16'h0,
                (i+1 < hwq.size()) ? hwq[i+1] : 16'h0,
                hwq[i]
            };
        end

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "EBREAK trap never fired");

        check("C.ADDI16SP (x2)",  dut.core0.regfile0.gp_registers[2],  64'd272);
        check("C.LI negative (x5)", dut.core0.regfile0.gp_registers[5], -64'sd5);
        check("C.LUI (x6)", dut.core0.regfile0.gp_registers[6], 64'h5000);
        check("addi (x7)", dut.core0.regfile0.gp_registers[7], 64'd100);
        check("C.MV + C.ADD (x9)", dut.core0.regfile0.gp_registers[9], 64'd107);
        check("dword-crossing addi (x12)", dut.core0.regfile0.gp_registers[12], 64'd108);
        check("C.J: not clobbered by skipped poison (x13)", dut.core0.regfile0.gp_registers[13], 64'd20);
        check("C.J: landed exactly on target (x14)", dut.core0.regfile0.gp_registers[14], 64'd25);
        check("C.AND result (x8)", dut.core0.regfile0.gp_registers[8], 64'd78);
        check("C.AND source unchanged (x11)", dut.core0.regfile0.gp_registers[11], 64'd222);
        check("C.SW/C.LW round trip (x15)", dut.core0.regfile0.gp_registers[15], 64'd78);
        check("C.BEQZ not taken -- fell through (x16)", dut.core0.regfile0.gp_registers[16], 64'd1);
        check("EBREAK trap fired (c.ebreak)", {63'b0, halted}, 64'd1);
        check("S_FETCH_HI genuinely visited for the crossing instruction",
            {63'b0, (fetch_hi_visit_count > 0)}, 64'd1);

        $display("");
        $display("core_c_ext_cache_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_c_ext_cache_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
