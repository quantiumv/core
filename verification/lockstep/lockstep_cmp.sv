/*
 * lockstep_cmp.sv -- pulls one record from each side's lockstep_rec
 * whenever both have one available, and compares them field by field.
 * Also drains and compares the two ordered bus-write logs, the two
 * ordered MMIO-read logs, and the two debug-event counts independently
 * (each its own FIFO-vs-FIFO stream, not gated on the retirement
 * stream), and watches for stall divergence (one side retiring while
 * the other doesn't, for STALL_CYCLES).
 *
 * +CORRUPT_AT=<order>/+CORRUPT_FIELD=<code> flips one field of side B's
 * popped record at that retirement order, before comparison -- proves
 * the comparator actually fails at exactly that record (see
 * run_lockstep.sh's corruption self-test).
 *
 * No fork, fixed control flow only -- Verilator-compatible per the plan.
 */

module lockstep_cmp #(
    parameter int HIST_DEPTH   = 16,
    parameter int STALL_CYCLES = 200000
) (
    input logic clk,
    input logic rst,

    // side A retirement pop interface
    input  logic         a_rec_avail,
    input  logic [31:0]  a_rec_total,
    output logic         a_rec_pop,
    input  logic [63:0]  a_order, a_pc_rdata, a_pc_wdata,
    input  logic [31:0]  a_insn,
    input  logic         a_trap, a_intr,
    input  logic [1:0]   a_mode,
    input  logic [4:0]   a_rd_addr,
    input  logic [63:0]  a_rd_wdata,
    input  logic [4:0]   a_rs1_addr,
    input  logic [63:0]  a_rs1_rdata,
    input  logic [4:0]   a_rs2_addr,
    input  logic [63:0]  a_rs2_rdata,
    input  logic [63:0]  a_mem_addr,
    input  logic [7:0]   a_mem_rmask, a_mem_wmask,
    input  logic [63:0]  a_mem_rdata, a_mem_wdata,
    input  logic [63:0]  a_cause, a_tval,
    input  logic [1:0]   a_current_priv,
    input  logic [63:0]  a_mtvec, a_stvec, a_mepc, a_sepc, a_mcause, a_scause,
    input  logic [63:0]  a_mtval, a_stval, a_satp, a_medeleg, a_mideleg,
    input  logic [63:0]  a_mie, a_mip, a_mscratch, a_sscratch, a_minstret,
    input  logic [63:0]  a_pmpcfg0, a_pmpaddr0, a_pmpaddr1, a_pmpaddr2, a_pmpaddr3,
    input  logic [63:0]  a_dcsr, a_dpc,
    input  logic [1:0]   a_mstatus_mpp,
    input  logic         a_mstatus_spp, a_mstatus_tsr, a_mstatus_mie, a_mstatus_sie,
    input  logic         a_mstatus_mprv, a_mstatus_sum, a_mstatus_mxr, a_mstatus_tvm,

    // side B retirement pop interface (same shape)
    input  logic         b_rec_avail,
    input  logic [31:0]  b_rec_total,
    output logic         b_rec_pop,
    input  logic [63:0]  b_order, b_pc_rdata, b_pc_wdata,
    input  logic [31:0]  b_insn,
    input  logic         b_trap, b_intr,
    input  logic [1:0]   b_mode,
    input  logic [4:0]   b_rd_addr,
    input  logic [63:0]  b_rd_wdata,
    input  logic [4:0]   b_rs1_addr,
    input  logic [63:0]  b_rs1_rdata,
    input  logic [4:0]   b_rs2_addr,
    input  logic [63:0]  b_rs2_rdata,
    input  logic [63:0]  b_mem_addr,
    input  logic [7:0]   b_mem_rmask, b_mem_wmask,
    input  logic [63:0]  b_mem_rdata, b_mem_wdata,
    input  logic [63:0]  b_cause, b_tval,
    input  logic [1:0]   b_current_priv,
    input  logic [63:0]  b_mtvec, b_stvec, b_mepc, b_sepc, b_mcause, b_scause,
    input  logic [63:0]  b_mtval, b_stval, b_satp, b_medeleg, b_mideleg,
    input  logic [63:0]  b_mie, b_mip, b_mscratch, b_sscratch, b_minstret,
    input  logic [63:0]  b_pmpcfg0, b_pmpaddr0, b_pmpaddr1, b_pmpaddr2, b_pmpaddr3,
    input  logic [63:0]  b_dcsr, b_dpc,
    input  logic [1:0]   b_mstatus_mpp,
    input  logic         b_mstatus_spp, b_mstatus_tsr, b_mstatus_mie, b_mstatus_sie,
    input  logic         b_mstatus_mprv, b_mstatus_sum, b_mstatus_mxr, b_mstatus_tvm,

    // ordered bus-write log streams
    input  logic         a_wr_avail, b_wr_avail,
    output logic         a_wr_pop, b_wr_pop,
    input  logic [31:0]  a_wrp_addr, b_wrp_addr,
    input  logic [7:0]   a_wrp_sel, b_wrp_sel,
    input  logic [63:0]  a_wrp_data, b_wrp_data,

    // ordered MMIO-read log streams
    input  logic         a_rd_avail, b_rd_avail,
    output logic         a_rd_pop, b_rd_pop,
    input  logic [31:0]  a_rdp_addr, b_rdp_addr,
    input  logic [63:0]  a_rdp_data, b_rdp_data,

    // debug-event counts
    input  logic         a_dbg_avail, b_dbg_avail,
    output logic         a_dbg_pop, b_dbg_pop,

    // corruption self-test (0 = disabled)
    input  logic [63:0]  corrupt_at,
    input  int           corrupt_field,

    output logic         result_fail,
    output logic [63:0]  fail_order,
    output logic [63:0]  match_count
);
    // -------------------- optional corruption of side B --------------------
    // cb_mcause corrupts b_mcause, the registered CSR snapshot (lags one
    // retirement behind for a trap's own self-referential update -- see
    // b_cause below). cb_cause is a SEPARATE signal for b_cause, the
    // derived per-retirement field (rvfi_csr_{m,s}cause_wdata via
    // route_to_s) -- these are two different fields that both happen to
    // be mcause-flavored, not the same value, and an earlier version of
    // this file compared a_cause against cb_mcause by mistake. That
    // produced a real false-positive divergence on an actual REF-vs-REF
    // run (two identical ref_core instances, different bus delay): the
    // live signals matched exactly at the retirement in question (traced
    // directly, both sides showing route_to_s=0, mcause_wdata=3), so the
    // bug was in this comparison, not in either core or the ring buffer.
    logic [63:0] cb_pc_rdata, cb_rd_wdata, cb_mem_addr, cb_mcause, cb_cause;
    logic        cb_trap;
    logic [31:0] cb_insn;
    logic        cb_mstatus_mie;
    wire         do_corrupt = (corrupt_at != 64'b0) && (b_order == corrupt_at);

    assign cb_pc_rdata    = b_pc_rdata    ^ ((do_corrupt && corrupt_field == 1) ? 64'h1 : 64'h0);
    assign cb_insn        = b_insn        ^ ((do_corrupt && corrupt_field == 2) ? 32'h1 : 32'h0);
    assign cb_rd_wdata    = b_rd_wdata    ^ ((do_corrupt && corrupt_field == 3) ? 64'h1 : 64'h0);
    assign cb_mem_addr    = b_mem_addr    ^ ((do_corrupt && corrupt_field == 4) ? 64'h8 : 64'h0);
    assign cb_mcause      = b_mcause      ^ ((do_corrupt && corrupt_field == 5) ? 64'h1 : 64'h0);
    assign cb_trap        = b_trap        ^ ((do_corrupt && corrupt_field == 6) ? 1'b1  : 1'b0);
    assign cb_mstatus_mie = b_mstatus_mie ^ ((do_corrupt && corrupt_field == 7) ? 1'b1  : 1'b0);
    assign cb_cause       = b_cause       ^ ((do_corrupt && corrupt_field == 8) ? 64'h1 : 64'h0);

    // -------------------- field-by-field comparison --------------------
    logic mismatch;
    always_comb begin
        mismatch = (a_order        != b_order)
                || (a_pc_rdata     != cb_pc_rdata)
                || (a_pc_wdata     != b_pc_wdata)
                || (a_insn         != cb_insn)
                || (a_trap         != cb_trap)
                || (a_intr         != b_intr)
                || (a_mode         != b_mode)
                || (a_rd_addr      != b_rd_addr)
                || ((a_rd_addr != 5'b0) && (a_rd_wdata != cb_rd_wdata))
                || (a_rs1_addr     != b_rs1_addr)
                || ((a_rs1_addr != 5'b0) && (a_rs1_rdata != b_rs1_rdata))
                || (a_rs2_addr     != b_rs2_addr)
                || ((a_rs2_addr != 5'b0) && (a_rs2_rdata != b_rs2_rdata))
                || (a_cause        != cb_cause)
                || (a_tval         != b_tval)
                || (a_current_priv != b_current_priv)
                || (a_mtvec != b_mtvec) || (a_stvec != b_stvec)
                || (a_mepc  != b_mepc)  || (a_sepc  != b_sepc)
                || (a_mcause != cb_mcause) || (a_scause != b_scause)
                || (a_mtval != b_mtval) || (a_stval != b_stval)
                || (a_satp != b_satp) || (a_medeleg != b_medeleg) || (a_mideleg != b_mideleg)
                || (a_mie != b_mie) || (a_mip != b_mip)
                || (a_mscratch != b_mscratch) || (a_sscratch != b_sscratch) || (a_minstret != b_minstret)
                || (a_pmpcfg0 != b_pmpcfg0)
                || (a_pmpaddr0 != b_pmpaddr0) || (a_pmpaddr1 != b_pmpaddr1)
                || (a_pmpaddr2 != b_pmpaddr2) || (a_pmpaddr3 != b_pmpaddr3)
                || (a_dcsr != b_dcsr) || (a_dpc != b_dpc)
                || (a_mstatus_mpp != b_mstatus_mpp)
                || (a_mstatus_spp != b_mstatus_spp) || (a_mstatus_tsr != b_mstatus_tsr)
                || (a_mstatus_mie != cb_mstatus_mie) || (a_mstatus_sie != b_mstatus_sie)
                || (a_mstatus_mprv != b_mstatus_mprv) || (a_mstatus_sum != b_mstatus_sum)
                || (a_mstatus_mxr != b_mstatus_mxr) || (a_mstatus_tvm != b_mstatus_tvm);
        // mem fields only compared for non-trapping instructions -- a
        // trapping instruction's RVFI mem_* shows a "would-be" access
        // shape on this core that a real trap on the reference side may
        // not show identically (same exclusion sail_diff.py uses).
        // rdata/wdata are additionally each only meaningful under their
        // OWN mask, per the RVFI convention (same don't-care-under-a-
        // zero-mask class of bug as o_cause's rvfi_csr_*_wdata, fixed in
        // lockstep_side.sv) -- comparing them unconditionally produced a
        // real false divergence at the very first retirement of an
        // actual cache-config run: rmask/wmask both read 00 (no memory
        // access at all this instruction) yet mem_rdata showed unrelated
        // nonzero content on one side, zero on the other.
        if (!a_trap && !cb_trap) begin
            mismatch = mismatch
                || (a_mem_addr  != cb_mem_addr)
                || (a_mem_rmask != b_mem_rmask) || (a_mem_wmask != b_mem_wmask)
                || ((a_mem_rmask != 8'b0) && (a_mem_rdata != b_mem_rdata))
                || ((a_mem_wmask != 8'b0) && (a_mem_wdata != b_mem_wdata));
        end
    end

    assign a_rec_pop = a_rec_avail && b_rec_avail && !result_fail;
    assign b_rec_pop = a_rec_avail && b_rec_avail && !result_fail;

    // -------------------- last-N-matched history, for the report --------------------
    logic [63:0] hist_pc   [0:HIST_DEPTH-1];
    logic [31:0] hist_insn [0:HIST_DEPTH-1];
    logic [$clog2(HIST_DEPTH)-1:0] hist_wp_q;
    int report_idx;

    always_ff @(posedge clk) begin
        if (rst) begin
            hist_wp_q <= '0;
        end else if (a_rec_pop && b_rec_pop && !mismatch) begin
            hist_pc[hist_wp_q]   <= a_pc_rdata;
            hist_insn[hist_wp_q] <= a_insn;
            hist_wp_q            <= hist_wp_q + 1'b1;
        end
    end

    logic [63:0] match_count_q;
    assign match_count = match_count_q;

    logic val_mismatch_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            val_mismatch_q <= 1'b0;
            fail_order     <= 64'b0;
            match_count_q  <= 64'b0;
        end else if (a_rec_pop && b_rec_pop && !val_mismatch_q) begin
            if (mismatch) begin
                val_mismatch_q <= 1'b1;
                fail_order     <= a_order;
                $display("LOCKSTEP_DIVERGENCE: first mismatch at retirement order=%0d", a_order);
                $display("  field         side_a                  side_b");
                $display("  order         %016h        %016h", a_order, b_order);
                $display("  pc_rdata      %016h        %016h", a_pc_rdata, cb_pc_rdata);
                $display("  pc_wdata      %016h        %016h", a_pc_wdata, b_pc_wdata);
                $display("  insn          %08h                %08h", a_insn, cb_insn);
                $display("  trap/intr     %0d/%0d                     %0d/%0d", a_trap, a_intr, cb_trap, b_intr);
                $display("  mode          %0d                       %0d", a_mode, b_mode);
                $display("  rd            %0d=%016h        %0d=%016h", a_rd_addr, a_rd_wdata, b_rd_addr, cb_rd_wdata);
                $display("  rs1           %0d=%016h        %0d=%016h", a_rs1_addr, a_rs1_rdata, b_rs1_addr, b_rs1_rdata);
                $display("  rs2           %0d=%016h        %0d=%016h", a_rs2_addr, a_rs2_rdata, b_rs2_addr, b_rs2_rdata);
                $display("  mem_addr      %016h        %016h", a_mem_addr, cb_mem_addr);
                $display("  mem_rmask/wmask %02h/%02h                %02h/%02h", a_mem_rmask, a_mem_wmask, b_mem_rmask, b_mem_wmask);
                $display("  mem_rdata     %016h        %016h", a_mem_rdata, b_mem_rdata);
                $display("  mem_wdata     %016h        %016h", a_mem_wdata, b_mem_wdata);
                $display("  cause/tval    %016h/%016h  %016h/%016h", a_cause, a_tval, cb_cause, b_tval);
                $display("  current_priv  %0d                       %0d", a_current_priv, b_current_priv);
                $display("  mtvec/stvec   %016h/%016h  %016h/%016h", a_mtvec, a_stvec, b_mtvec, b_stvec);
                $display("  mepc/sepc     %016h/%016h  %016h/%016h", a_mepc, a_sepc, b_mepc, b_sepc);
                $display("  mcause/scause %016h/%016h  %016h/%016h", a_mcause, a_scause, cb_mcause, b_scause);
                $display("  mtval/stval   %016h/%016h  %016h/%016h", a_mtval, a_stval, b_mtval, b_stval);
                $display("  satp          %016h        %016h", a_satp, b_satp);
                $display("  medeleg/mideleg %016h/%016h  %016h/%016h", a_medeleg, a_mideleg, b_medeleg, b_mideleg);
                $display("  mie/mip       %016h/%016h  %016h/%016h", a_mie, a_mip, b_mie, b_mip);
                $display("  mscratch/sscratch %016h/%016h  %016h/%016h", a_mscratch, a_sscratch, b_mscratch, b_sscratch);
                $display("  minstret      %016h        %016h", a_minstret, b_minstret);
                $display("  pmpcfg0       %016h        %016h", a_pmpcfg0, b_pmpcfg0);
                $display("  pmpaddr0-3    %016h %016h %016h %016h", a_pmpaddr0, a_pmpaddr1, a_pmpaddr2, a_pmpaddr3);
                $display("                %016h %016h %016h %016h", b_pmpaddr0, b_pmpaddr1, b_pmpaddr2, b_pmpaddr3);
                $display("  dcsr/dpc      %016h/%016h  %016h/%016h", a_dcsr, a_dpc, b_dcsr, b_dpc);
                $display("  mstatus bits  mpp=%0d spp=%0d tsr=%0d mie=%0d sie=%0d mprv=%0d sum=%0d mxr=%0d tvm=%0d",
                         a_mstatus_mpp, a_mstatus_spp, a_mstatus_tsr, a_mstatus_mie, a_mstatus_sie,
                         a_mstatus_mprv, a_mstatus_sum, a_mstatus_mxr, a_mstatus_tvm);
                $display("                mpp=%0d spp=%0d tsr=%0d mie=%0d sie=%0d mprv=%0d sum=%0d mxr=%0d tvm=%0d",
                         b_mstatus_mpp, b_mstatus_spp, b_mstatus_tsr, cb_mstatus_mie, b_mstatus_sie,
                         b_mstatus_mprv, b_mstatus_mxr, b_mstatus_sum, b_mstatus_tvm);
                $display("  last %0d matched {pc,insn} pairs before the divergence:", HIST_DEPTH);
                for (int k = 0; k < HIST_DEPTH; k++) begin
                    report_idx = (hist_wp_q + k) % HIST_DEPTH;
                    $display("    pc=%016h insn=%08h", hist_pc[report_idx], hist_insn[report_idx]);
                end
            end else begin
                match_count_q <= match_count_q + 1'b1;
            end
        end
    end

    // -------------------- ordered bus-write log comparison --------------------
    logic wr_mismatch_q;
    assign a_wr_pop = a_wr_avail && b_wr_avail && !wr_mismatch_q;
    assign b_wr_pop = a_wr_avail && b_wr_avail && !wr_mismatch_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_mismatch_q <= 1'b0;
        end else if (a_wr_pop && b_wr_pop && !wr_mismatch_q) begin
            if (a_wrp_addr != b_wrp_addr || a_wrp_sel != b_wrp_sel || a_wrp_data != b_wrp_data) begin
                wr_mismatch_q <= 1'b1;
                $display("LOCKSTEP_DIVERGENCE: bus-write log mismatch: a={addr=%08h sel=%02h data=%016h} b={addr=%08h sel=%02h data=%016h}",
                         a_wrp_addr, a_wrp_sel, a_wrp_data, b_wrp_addr, b_wrp_sel, b_wrp_data);
            end
        end
    end

    // -------------------- ordered mmio-read log comparison --------------------
    logic rd_mismatch_q;
    assign a_rd_pop = a_rd_avail && b_rd_avail && !rd_mismatch_q;
    assign b_rd_pop = a_rd_avail && b_rd_avail && !rd_mismatch_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_mismatch_q <= 1'b0;
        end else if (a_rd_pop && b_rd_pop && !rd_mismatch_q) begin
            if (a_rdp_addr != b_rdp_addr || a_rdp_data != b_rdp_data) begin
                rd_mismatch_q <= 1'b1;
                $display("LOCKSTEP_DIVERGENCE: mmio-read log mismatch: a={addr=%08h data=%016h} b={addr=%08h data=%016h}",
                         a_rdp_addr, a_rdp_data, b_rdp_addr, b_rdp_data);
            end
        end
    end

    // -------------------- debug-event count comparison --------------------
    logic dbg_mismatch_q;
    assign a_dbg_pop = a_dbg_avail && b_dbg_avail && !dbg_mismatch_q;
    assign b_dbg_pop = a_dbg_avail && b_dbg_avail && !dbg_mismatch_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            dbg_mismatch_q <= 1'b0;
        end else if ((a_dbg_avail ^ b_dbg_avail) && !dbg_mismatch_q) begin
            // one side has a pending debug-entry event and the other
            // never produced a matching one to drain against.
            dbg_mismatch_q <= 1'b1;
            $display("LOCKSTEP_DIVERGENCE: debug-entry event count diverged (a_avail=%0d b_avail=%0d)", a_dbg_avail, b_dbg_avail);
        end
    end

    // -------------------- stall divergence --------------------
    // Tracks each side's lifetime retirement count (monotonic, from
    // lockstep_rec.sv) rather than its ring occupancy -- occupancy alone
    // can't tell "stopped retiring" apart from "backlog because the
    // other side already fell behind".
    logic [31:0] a_total_prev_q, b_total_prev_q;
    logic [31:0] a_stall_cnt_q, b_stall_cnt_q;
    logic        stall_fail_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            a_total_prev_q <= '0;
            b_total_prev_q <= '0;
            a_stall_cnt_q  <= '0;
            b_stall_cnt_q  <= '0;
            stall_fail_q   <= 1'b0;
        end else begin
            a_total_prev_q <= a_rec_total;
            b_total_prev_q <= b_rec_total;
            a_stall_cnt_q  <= (a_rec_total != a_total_prev_q) ? 32'b0 : a_stall_cnt_q + 1'b1;
            b_stall_cnt_q  <= (b_rec_total != b_total_prev_q) ? 32'b0 : b_stall_cnt_q + 1'b1;
            if (!stall_fail_q && !val_mismatch_q) begin
                if ((b_rec_total == b_total_prev_q) && (a_rec_total != a_total_prev_q) &&
                    (b_stall_cnt_q > STALL_CYCLES[31:0])) begin
                    stall_fail_q <= 1'b1;
                    $display("LOCKSTEP_DIVERGENCE: side B has not retired in %0d cycles while side A keeps retiring", STALL_CYCLES);
                end else if ((a_rec_total == a_total_prev_q) && (b_rec_total != b_total_prev_q) &&
                             (a_stall_cnt_q > STALL_CYCLES[31:0])) begin
                    stall_fail_q <= 1'b1;
                    $display("LOCKSTEP_DIVERGENCE: side A has not retired in %0d cycles while side B keeps retiring", STALL_CYCLES);
                end
            end
        end
    end

    assign result_fail = val_mismatch_q || wr_mismatch_q || rd_mismatch_q || dbg_mismatch_q || stall_fail_q;
endmodule
