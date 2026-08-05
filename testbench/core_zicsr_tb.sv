// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's Zicsr (CSR instruction) support, end to end.
 *
 * Same wiring spirit as core_wb_tb.sv (real wb4_sram instance, core wired
 * directly to it as the sole Wishbone master) but simpler: this program
 * never issues a load/store, so there's no memory-mapped I/O to route --
 * core's Wishbone port connects STRAIGHT to wb4_sram, with no
 * wb_addr_decoder/uart_tx in between (unlike core_wb_tb.sv, which needs
 * both because its program does touch the UART).
 *
 * Instructions are packed two-per-64-bit-word directly into the SRAM's
 * memory[] array, exactly like core_wb_tb.sv: byte address a's
 * instruction lands in memory[a/8][31:0] if a[2]=0, else
 * memory[a/8][63:32], matching core.sv's own pc[2] half-select. The poke
 * is delayed by #1 past time 0 for the same reason core_wb_tb.sv's is --
 * so it runs after wb4_sram's own time-0 zero-fill+$readmemh init instead
 * of racing it.
 *
 * Exercises, in program order:
 *  1. csrrwi write-attempt to the read-only mhartid, then a csrrw read
 *     to confirm the write never landed.
 *  2. csrrs read of misa, checked against the exact hardwired bit
 *     pattern.
 *  3. csrrw write + csrrs read-back on mscratch (the "vanilla CSR" round
 *     trip).
 *  4. csrrs-set then csrrc-clear on mscratch, with a read-back check
 *     after each.
 *  5. The rd=x0 case (csrrwi x0, mscratch, ...) still performs its write
 *     -- confirmed by a subsequent read.
 *  6. That same subsequent read doubles as the rs1=x0 case: a pure read
 *     with zero mutation. Register-value-only checks can't distinguish
 *     "correctly suppressed" from "coincidentally value-preserving"
 *     here (mscratch | 0 == mscratch either way) -- see the plan's
 *     "known test-design limitation" note -- so this is supplemented
 *     with a white-box hierarchical check that dut.csr_we itself reads
 *     0 during that specific instruction's S_EXEC cycle, for genuine
 *     confidence rather than a check that would pass even if
 *     suppression were silently broken.
 *  7. A final minstret read matching the exact known instruction count
 *     retired so far, plus a post-halt hierarchical check that
 *     minstret's storage ends at the full program length -- including
 *     ebreak itself, which retires (and so still increments minstret)
 *     even though it doesn't write a register.
 *  8. ebreak.
 *
 * Deliberately NOT re-proven here (already covered by core_wb_tb.sv):
 * ordinary ALU/load/store/branch datapath behavior. This test's only
 * job is Zicsr.
 */
module core_zicsr_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    core dut (
        .clk(clk), .rst(rst),
        .wb_addr_o(wb_addr), .wb_dat_o(wb_dat_m2s), .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack), .wb_err_i(wb_err)
    );

    wb4_sram #(.num_words(64)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .ack_o(wb_ack), .err_o(wb_err), .cyc_i(wb_cyc), .stb_i(wb_stb), .we_i(wb_we)
    );

    int pass_count = 0;
    int fail_count = 0;
    task automatic check(string name, logic [63:0] actual, logic [63:0] expected);
        if (actual === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    /*
     * White-box hierarchical monitor for the rs1=x0 case (see header
     * comment, item 6): watches for the exact cycle where the program
     * counter is at the "csrrs x13, mscratch, x0" instruction's address
     * (0x34, idx13 below) AND the FSM is in its single settle-and-retire
     * state, then latches dut.csr_we right there. Sampled on negedge
     * clk, well clear of the posedge that drives dut.state's own
     * always_ff -- state (and everything combinationally derived from
     * it, including csr_we) is stable for the entire S_EXEC cycle, so
     * negedge is a race-free place to look. state_t's declared order in
     * core.sv is {S_FETCH, S_EXEC, S_MEM} = {0, 1, 2} for its 2-bit
     * enum, hence the literal 2'd1 below.
     */
    localparam logic [63:0] PC_RS1_X0_CHECK = 64'h34;
    logic csr_we_sampled;
    logic csr_we_sample_captured = 1'b0;
    always @(negedge clk) begin
        if (!csr_we_sample_captured && dut.state == 2'd1 && dut.pc == PC_RS1_X0_CHECK) begin
            csr_we_sampled = dut.csr_we;
            csr_we_sample_captured = 1'b1;
        end
    end

    initial begin
        #1; // see header comment: run after wb4_sram's own time-0 init

        /*
         * addr  idx  instruction                              notes
         *  0x00   0  csrrwi x1, mhartid, 7                     write-attempt to read-only CSR; x1 = old mhartid = 0
         *  0x04   1  csrrw  x2, mhartid, x0                    re-read mhartid; x2 must still be 0 (write from idx0 didn't land)
         *  0x08   2  csrrs  x3, misa, x0                       pure read; x3 = exact hardwired misa pattern
         *  0x0C   3  addi   x4, x0, 240                        x4 = 0xF0, seed value for mscratch
         *  0x10   4  csrrw  x5, mscratch, x4                   write x4 into mscratch; x5 = old mscratch = 0
         *  0x14   5  csrrs  x6, mscratch, x0                   read back; x6 = 0xF0
         *  0x18   6  addi   x7, x0, 15                         x7 = 0x0F, set-mask
         *  0x1C   7  csrrs  x8, mscratch, x7                   OR mask in; x8 = old mscratch = 0xF0, mscratch becomes 0xFF
         *  0x20   8  csrrs  x9, mscratch, x0                   read back; x9 = 0xFF
         *  0x24   9  addi   x10, x0, 240                       x10 = 0xF0, clear-mask
         *  0x28  10  csrrc  x11, mscratch, x10                 AND ~mask in; x11 = old mscratch = 0xFF, mscratch becomes 0x0F
         *  0x2C  11  csrrs  x12, mscratch, x0                  read back; x12 = 0x0F
         *  0x30  12  csrrwi x0, mscratch, 27                   rd=x0 case: mscratch write must still land (mscratch becomes 27)
         *  0x34  13  csrrs  x13, mscratch, x0                  rd=x0 confirm (x13 = 27) AND the rs1=x0 white-box check instruction
         *  0x38  14  csrrs  x14, minstret, x0                  minstret read; x14 = count of instructions retired strictly before this one = 14
         *  0x3C  15  ebreak                                    halts; also retires, so minstret's final storage = 16
         */
        sram0.memory[0] = {encode_csr(`CSR_MHARTID, 5'd0, `FUNCT3_CSRRW,  5'd2, `OPC_SYSTEM),
                            encode_csr(`CSR_MHARTID, 5'd7, `FUNCT3_CSRRWI, 5'd1, `OPC_SYSTEM)};
        sram0.memory[1] = {encode_i(32'sd240, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM),
                            encode_csr(`CSR_MISA, 5'd0, `FUNCT3_CSRRS, 5'd3, `OPC_SYSTEM)};
        sram0.memory[2] = {encode_csr(`CSR_MSCRATCH, 5'd0, `FUNCT3_CSRRS, 5'd6, `OPC_SYSTEM),
                            encode_csr(`CSR_MSCRATCH, 5'd4, `FUNCT3_CSRRW, 5'd5, `OPC_SYSTEM)};
        sram0.memory[3] = {encode_csr(`CSR_MSCRATCH, 5'd7, `FUNCT3_CSRRS, 5'd8, `OPC_SYSTEM),
                            encode_i(32'sd15, 5'd0, 3'b000, 5'd7, `OPC_OP_IMM)};
        sram0.memory[4] = {encode_i(32'sd240, 5'd0, 3'b000, 5'd10, `OPC_OP_IMM),
                            encode_csr(`CSR_MSCRATCH, 5'd0, `FUNCT3_CSRRS, 5'd9, `OPC_SYSTEM)};
        sram0.memory[5] = {encode_csr(`CSR_MSCRATCH, 5'd0,  `FUNCT3_CSRRS, 5'd12, `OPC_SYSTEM),
                            encode_csr(`CSR_MSCRATCH, 5'd10, `FUNCT3_CSRRC, 5'd11, `OPC_SYSTEM)};
        sram0.memory[6] = {encode_csr(`CSR_MSCRATCH, 5'd0,  `FUNCT3_CSRRS,  5'd13, `OPC_SYSTEM),
                            encode_csr(`CSR_MSCRATCH, 5'd27, `FUNCT3_CSRRWI, 5'd0,  `OPC_SYSTEM)};
        sram0.memory[7] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                                     // idx15: ebreak (0x3C)
                            encode_csr(`CSR_MINSTRET, 5'd0, `FUNCT3_CSRRS, 5'd14, `OPC_SYSTEM)};   // idx14: csrrs x14, minstret, x0 (0x38)

        @(posedge clk); #1;
        rst = 0;

        fork
            wait (dut.halted === 1'b1);
            begin
                repeat (200) @(posedge clk);
                $display("TIMEOUT: dut.halted never went high");
                $finish;
            end
        join_any
        #1;

        check("x1 (csrrwi rd, old mhartid before write-attempt)", dut.regfile0.gp_registers[1], 64'd0);
        check("x2 (csrrw rd, mhartid after write-attempt -- confirms it didn't land)",
              dut.regfile0.gp_registers[2], 64'd0);
        check("x3 (csrrs rd, misa exact bit pattern)", dut.regfile0.gp_registers[3], 64'h8000_0000_0000_0100);

        check("x5 (csrrw rd, old mscratch before first write)", dut.regfile0.gp_registers[5], 64'd0);
        check("x6 (mscratch read-back after csrrw)", dut.regfile0.gp_registers[6], 64'h00F0);

        check("x8 (csrrs rd, old mscratch before set)", dut.regfile0.gp_registers[8], 64'h00F0);
        check("x9 (mscratch read-back after csrrs-set)", dut.regfile0.gp_registers[9], 64'h00FF);

        check("x11 (csrrc rd, old mscratch before clear)", dut.regfile0.gp_registers[11], 64'h00FF);
        check("x12 (mscratch read-back after csrrc-clear)", dut.regfile0.gp_registers[12], 64'h000F);

        check("x13 (mscratch read-back -- confirms rd=x0 csrrwi write still landed)",
              dut.regfile0.gp_registers[13], 64'd27);

        check("white-box sample was actually captured (sanity on the monitor itself)",
              {63'b0, csr_we_sample_captured}, 64'd1);
        check("rs1=x0 case: dut.csr_we reads 0 during that instruction's S_EXEC (true suppression, not coincidence)",
              {63'b0, csr_we_sampled}, 64'd0);

        check("x14 (minstret read -- count of instructions retired strictly before this one)",
              dut.regfile0.gp_registers[14], 64'd14);
        check("minstret final storage -- full program length, including ebreak's own retirement",
              dut.csr_file0.minstret_q, 64'd16);

        check("core halted (ebreak reached)", {63'b0, dut.halted}, 64'd1);

        $display("");
        $display("core_zicsr_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_zicsr_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
