// SPDX-License-Identifier: MIT

/*
 * run_soc_tb -- runs any program on the full SoC (design/soc.sv): the
 * testbench behind `make run` (verification/run/run_prog.sh).
 *
 * Plusargs:
 *   +HEXFILE=<path>    required; objcopy -O verilog --verilog-data-width=8
 *   +MAX_CYCLES=<n>    default 10000000
 *   +TRACE=<path>      needs -DRISCV_FORMAL: one line per retirement, in
 *                      testbench/rvfi_tracer.sv's format (so
 *                      verification/pipe/cmp_rvfi.py can diff two cores)
 *
 * wb4_sram already zeroed RAM and loaded firmware/crt0.hex at time 0 (its
 * hardcoded image); the program replaces that at time 1, after zeroing
 * RAM again. The run ends at the EBREAK firmware/crt0.s executes when
 * main() returns, with main's return value in a0. Any other trap while
 * mtvec is still 0 also ends it, reported: with no handler installed it
 * would send the program back to _start, to start over silently. A
 * program that installs its own mtvec handles its own traps.
 */
module run_soc_tb;
    localparam int RAM_WORDS = 8388608;    // soc.sv's 64MB wb4_sram

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    soc dut (.clk(clk), .rst(rst));

    string  hex_path, trace_path;
    longint max_cycles;
    longint cycle = 0;
    int     trace_fd = 0;

    initial begin
        if (!$value$plusargs("HEXFILE=%s", hex_path)) begin
            $display("run_soc_tb: +HEXFILE=<program.hex> is required");
            $finish;
        end
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 10000000;
        if ($value$plusargs("TRACE=%s", trace_path)) begin
`ifdef RISCV_FORMAL
            trace_fd = $fopen(trace_path, "w");
`else
            $display("run_soc_tb: +TRACE needs a -DRISCV_FORMAL build, ignored");
`endif
        end
        #1;
        for (int i = 0; i < RAM_WORDS; i++) dut.sram0.memory[i] = '0;
        $readmemh(hex_path, dut.sram0.memory);
        @(posedge clk); #1;
        rst = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst) begin
            cycle <= cycle + 1;
            if (dut.core0.trap_taken && dut.core0.is_ebreak) begin
                $display("");
                $display("run_soc_tb: ebreak after %0d cycles, %0d instructions retired, exit code %0d (a0)",
                         cycle, dut.core0.csr_file0.minstret_q,
                         $signed(dut.core0.regfile0.gp_registers[10]));
                if (trace_fd != 0) $fclose(trace_fd);
                $finish;
            end else if (dut.core0.csr_file0.i_trap_taken && dut.core0.csr_file0.mtvec_q[63:2] == '0) begin
                // with no handler installed this would restart the program
                $display("");
                $display("run_soc_tb: unhandled trap at cycle %0d: cause=%0d pc=%h tval=%h (mtvec=0, stopping)",
                         cycle, $signed(dut.core0.csr_file0.i_trap_cause), dut.core0.pc,
                         dut.core0.csr_file0.i_trap_val);
                if (trace_fd != 0) $fclose(trace_fd);
                $finish;
            end
            if (cycle >= max_cycles) begin
                $display("");
                $display("run_soc_tb: TIMEOUT after %0d cycles (pc=%h)", cycle, dut.core0.pc);
                if (trace_fd != 0) $fclose(trace_fd);
                $finish;
            end
        end
    end

`ifdef RISCV_FORMAL
    // one line per retirement, channel 0 (the oldest) first; NRET as testbench/rvfi_tracer.sv has it
`ifndef QV_PIPE_COMMIT_W
`define QV_PIPE_COMMIT_W 2                // the core's default (design/pipe/core.sv)
`endif
`ifdef QV_REF_AS_CORE
    localparam int NRET = 1;
`else
    localparam int NRET = `QV_PIPE_COMMIT_W;
`endif
    always @(posedge clk) begin
        if (trace_fd != 0)
            for (int ch = 0; ch < NRET; ch++) if (dut.core0.rvfi_valid[ch])
                $fdisplay(trace_fd, "rvfi order=%0d pc_rdata=%h pc_wdata=%h insn=%h mode=%0d trap=%b intr=%b cause=%h tval=%h rd_addr=%0d rd_wdata=%h rs1_addr=%0d rs1_rdata=%h rs2_addr=%0d rs2_rdata=%h mem_addr=%h mem_rmask=%h mem_wmask=%h mem_rdata=%h mem_wdata=%h",
                    dut.core0.rvfi_order[64*ch +: 64], dut.core0.rvfi_pc_rdata[64*ch +: 64], dut.core0.rvfi_pc_wdata[64*ch +: 64],
                    dut.core0.rvfi_insn[32*ch +: 32], dut.core0.rvfi_mode[2*ch +: 2], dut.core0.rvfi_trap[ch], dut.core0.rvfi_intr[ch],
                    dut.core0.rvfi_trap[ch] ? (dut.core0.route_to_s ? dut.core0.rvfi_csr_scause_wdata[64*ch +: 64]
                                                                    : dut.core0.rvfi_csr_mcause_wdata[64*ch +: 64]) : 64'b0,
                    dut.core0.rvfi_trap[ch] ? dut.core0.trap_val : 64'b0,
                    dut.core0.rvfi_rd_addr[5*ch +: 5], dut.core0.rvfi_rd_wdata[64*ch +: 64],
                    dut.core0.rvfi_rs1_addr[5*ch +: 5], dut.core0.rvfi_rs1_rdata[64*ch +: 64],
                    dut.core0.rvfi_rs2_addr[5*ch +: 5], dut.core0.rvfi_rs2_rdata[64*ch +: 64],
                    dut.core0.rvfi_mem_addr[64*ch +: 64], dut.core0.rvfi_mem_rmask[8*ch +: 8], dut.core0.rvfi_mem_wmask[8*ch +: 8],
                    dut.core0.rvfi_mem_rdata[64*ch +: 64], dut.core0.rvfi_mem_wdata[64*ch +: 64]);
    end
`endif
endmodule
