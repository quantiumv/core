// SPDX-License-Identifier: MIT

/*
 * qv_commit -- retires the ROB head, one instruction per cycle, and owns
 * every architectural side effect: the regfile0 write, csr_file0's
 * retirement count (via core_pipe), the producer-table release back to
 * issue, the architectural PC, and RVFI.
 *
 * RVFI follows core.sv's own conventions field for field (core.sv's RVFI
 * assign block): rd_addr is 0 unless the instruction writes rd, rd_wdata
 * is 0 unless it writes a nonzero rd, intr flags a retirement whose pc
 * doesn't follow the previous retirement's pc_wdata, mode is the
 * privilege level and ixl is 2 (always 64-bit). Source operands come
 * from the values issue captured (rvfi_shadow_t), since regfile0's read
 * ports aren't free to re-read them here.
 *
 * Redirect: retiring an entry marked mispredict pulses o_redirect with
 * the entry's resolved next pc. That same cycle the entry retires
 * normally and everything younger is flushed.
 *
 * Not yet: traps (a faulting uop retires as a no-op -- decode already
 * cleared its rd_wen) and memory fields (always 0).
 */
module qv_commit #(
    parameter logic [63:0] RESET_PC = 64'h0
) (
    input  logic                             clk,
    input  logic                             rst,

    input  logic                             i_head_valid,
    // the entry's own .valid duplicates i_head_valid
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::rob_entry_t               i_head_entry,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_head_tag,
    input  qv_pkg::rvfi_shadow_t             i_head_shadow,
    output logic                             o_commit_pop,

    output logic                             o_regfile_we,
    output logic [4:0]                       o_regfile_sel,
    output logic [63:0]                      o_regfile_data,

    output logic                             o_commit_valid,
    output logic [4:0]                       o_commit_rd,
    output logic                             o_commit_rd_wen,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_commit_tag,

    output logic                             o_commit_now,
    output logic [63:0]                      o_pc,
    output logic [63:0]                      o_next_pc,

    output logic                             o_redirect_valid,
    output logic [63:0]                      o_redirect_pc,

    output logic [63:0]                      o_rvfi_order,
    output logic [31:0]                      o_rvfi_insn,
    output logic                             o_rvfi_intr,
    output logic [4:0]                       o_rvfi_rs1_addr,
    output logic [4:0]                       o_rvfi_rs2_addr,
    output logic [63:0]                      o_rvfi_rs1_rdata,
    output logic [63:0]                      o_rvfi_rs2_rdata,
    output logic [4:0]                       o_rvfi_rd_addr,
    output logic [63:0]                      o_rvfi_rd_wdata,
    output logic [63:0]                      o_rvfi_pc_rdata,
    output logic [63:0]                      o_rvfi_pc_wdata
);
    wire commit = i_head_valid && i_head_entry.complete;

    assign o_commit_pop = commit;
    assign o_commit_now = commit;

    assign o_regfile_we   = commit && i_head_entry.rd_wen;
    assign o_regfile_sel  = i_head_entry.rd;
    assign o_regfile_data = i_head_entry.value;

    assign o_commit_valid  = commit;
    assign o_commit_rd     = i_head_entry.rd;
    assign o_commit_rd_wen = i_head_entry.rd_wen;
    assign o_commit_tag    = i_head_tag;

    // architectural PC: the next instruction to retire
    logic [63:0] arch_pc_q;
    always_ff @(posedge clk) begin
        if (rst)         arch_pc_q <= RESET_PC;
        else if (commit) arch_pc_q <= i_head_entry.next_pc;
    end
    assign o_pc      = arch_pc_q;
    assign o_next_pc = i_head_entry.next_pc;

    assign o_redirect_valid = commit && i_head_entry.mispredict;
    assign o_redirect_pc    = i_head_entry.next_pc;

    // ---------------- RVFI ----------------
    logic [63:0] order_q, prev_pc_wdata_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            order_q         <= 64'b0;
            prev_pc_wdata_q <= RESET_PC;
        end else if (commit) begin
            order_q         <= order_q + 64'd1;
            prev_pc_wdata_q <= i_head_entry.next_pc;
        end
    end

    assign o_rvfi_order     = order_q;
    assign o_rvfi_insn      = i_head_entry.raw;
    assign o_rvfi_intr      = commit && (i_head_entry.pc != prev_pc_wdata_q);
    assign o_rvfi_rs1_addr  = i_head_shadow.rs1_addr;
    assign o_rvfi_rs2_addr  = i_head_shadow.rs2_addr;
    assign o_rvfi_rs1_rdata = i_head_shadow.rs1_rdata;
    assign o_rvfi_rs2_rdata = i_head_shadow.rs2_rdata;
    assign o_rvfi_rd_addr   = i_head_entry.rd_wen ? i_head_entry.rd : 5'b0;
    assign o_rvfi_rd_wdata  = (i_head_entry.rd_wen && i_head_entry.rd != 5'b0) ? i_head_entry.value : 64'b0;
    assign o_rvfi_pc_rdata  = i_head_entry.pc;
    assign o_rvfi_pc_wdata  = i_head_entry.next_pc;
endmodule
