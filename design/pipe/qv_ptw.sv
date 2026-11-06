// SPDX-License-Identifier: MIT

/*
 * qv_ptw -- the Sv39 page-table walker of the core: one walker, two clients
 * (D, the data side, and F, the instruction side), one bus master port.
 *
 * A client holds its request (i_x_req with the VA and the context it is
 * translated in) until it sees its done pulse or cancels it; the walker
 * accepts a request only when idle, so there is at most one walk and its
 * context is latched at that moment. D wins a tie at an idle walker. A walk
 * is never preempted.
 *
 * A walk is up to three PTE reads, level 2, 1, 0. For each: the address is
 * table base + vpn * 8; the PMP checks the read at S privilege (read only,
 * no M exemption, no match = deny: ref_core.sv's rule for a page-table access)
 * and a denied read never reaches the bus; the read is a dword beat on the
 * bus port (we = 0, sel = FF, lock = 0 are the user's to tie, as ref_core.sv
 * does). The response is registered and judged a cycle later by qv_pte, so
 * the bus data stays out of long paths. A bus error beats the PTE contents.
 * The walk ends with exactly one done pulse for the client:
 *   o_res_ok  a leaf without a fault for this access: the fields below are
 *             what the TLB caches
 *   o_res_pf  a page fault of the access's class (12/13/15 is the caller's
 *             to choose)
 *   o_res_af  an access fault of the access's class: the PTE read was
 *             denied by the PMP or the bus answered with an error
 *
 * A cancel never abandons a beat: the beat in flight completes, its result
 * is dropped, no further beat starts, and the walker is busy until then (so
 * one stale bit stays exact). A cancel in the cycle the walker would have
 * started a beat means no beat. The walker ignores ack and err unless its
 * own beat is in flight (the bus is shared and the formal wrapper drives them
 * freely), and drops cyc in the response cycle (wb_arbiter2 releases the
 * grant when the granted master's cyc is low).
 *
 * The bus belongs to the LSU first: a beat starts only when i_lsu_busy
 * (its start condition this cycle, or an access started and not yet
 * retired) is low, and o_beat tells the LSU a beat is in flight, so the
 * two can never drive the bus in the same cycle. The LSU wins every gap
 * between two beats of a walk.
 *
 * Wrong-path walks and devices (P10d): F walks speculatively, on wrong paths too, and a PTE read with a read side
 * effect (a PLIC claim, a UART receive register) must not happen for an instruction that never executes. With a
 * RAM window (PMA_RAM_SIZE != 0, the same one the store buffer uses), an F beat whose PTE address is outside it
 * goes out only once i_f_nonspec says the fetch is on the architectural path (nothing older is left in the
 * pipeline); until then the walk waits before the beat, costing nothing. If D asks meanwhile, F is given up (back
 * to idle, no result: its request stays, and it is accepted again once D's walk is done), so the head's data walk
 * is never blocked by a fetch walk waiting for the head to drain. A PMP denial is judged before the wait. D's walks
 * belong to the head and never wait. Only timing changes: a walk that reads the address does so on the real path.
 */
module qv_ptw #(
    parameter logic [63:0] PMA_RAM_BASE = 64'h0,
    parameter logic [63:0] PMA_RAM_SIZE = 64'h0      // 0: no window, F never waits
) (
    input  logic        clk,
    input  logic        rst,

    // the bus port
    output logic [31:0] o_bus_addr,
    output logic        o_bus_cyc,                 // stb is the same; we = 0, sel = FF, lock = 0
    input  logic [63:0] i_bus_dat,
    input  logic        i_bus_ack,
    input  logic        i_bus_err,

    // sharing the port with the LSU
    input  logic        i_lsu_busy,
    output logic        o_beat,

    // csr_file0's PMP exports
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] i_pmpcfg0,
    input  logic [63:0] i_pmpaddr0,
    input  logic [63:0] i_pmpaddr1,
    input  logic [63:0] i_pmpaddr2,
    input  logic [63:0] i_pmpaddr3,
    /* verilator lint_on UNUSEDSIGNAL */

    // client D (data): the request is held until o_d_done or i_d_cancel
    input  logic        i_d_req,
    input  logic [63:0] i_d_va,
    input  logic        i_d_wr,
    input  logic [1:0]  i_d_priv,                  // the privilege the permission check runs at
    input  logic        i_d_sum,
    input  logic        i_d_mxr,
    input  logic [43:0] i_d_root,                  // satp.PPN
    input  logic        i_d_cancel,
    output logic        o_d_done,

    // client F (instruction fetch)
    input  logic        i_f_req,
    input  logic [63:0] i_f_va,
    input  logic [1:0]  i_f_priv,
    input  logic [43:0] i_f_root,
    input  logic        i_f_cancel,
    output logic        o_f_done,
    input  logic        i_f_nonspec = 1'b1,        // the fetch being walked for is on the architectural path

    // the result, valid in the cycle of a done pulse
    output logic        o_res_ok,
    output logic        o_res_pf,
    output logic        o_res_af,
    output logic [26:0] o_res_vpn,                 // VA[38:12] of the walk
    output logic [1:0]  o_res_level,               // the level of the leaf
    output logic [43:0] o_res_ppn,                 // the leaf's own page number, as it is in the PTE
    output logic        o_res_r,
    output logic        o_res_w,
    output logic        o_res_x,
    output logic        o_res_u,
    output logic        o_res_d
);
    localparam logic [1:0] W_IDLE = 2'd0, W_GO = 2'd1, W_BEAT = 2'd2, W_DEC = 2'd3;

    logic [1:0]  st_q;
    logic        cl_q;                  // 0 = D, 1 = F: the client being served
    logic        stale_q;               // cancelled since it was accepted
    logic [63:0] va_q;
    logic [1:0]  level_q;
    logic [43:0] base_q;                // page number of the table being read
    logic        is_mem_q, wr_q, sum_q, mxr_q;
    logic [1:0]  priv_q;
    logic        beat_q;
    logic [63:0] pte_q;
    logic        err_q;
    logic        d_done_q, f_done_q;

    logic        res_ok_q, res_pf_q, res_af_q;
    logic [26:0] res_vpn_q;
    logic [1:0]  res_level_q;
    logic [43:0] res_ppn_q;
    logic        res_r_q, res_w_q, res_x_q, res_u_q, res_d_q;

    // ---------------- accepting a request ----------------
    // a client whose done pulse is showing is not asked again (it drops its request in that cycle)
    wire d_can = i_d_req && !i_d_cancel && !d_done_q;
    wire f_can = i_f_req && !i_f_cancel && !f_done_q;
    wire accept_d = (st_q == W_IDLE) && d_can;
    wire accept_f = (st_q == W_IDLE) && !d_can && f_can;

    wire cancel_srv = cl_q ? i_f_cancel : i_d_cancel;
    wire stale_eff  = stale_q || cancel_srv;

    // ---------------- this level's PTE read ----------------
    wire [8:0]  vpn_cur  = (level_q == 2'd2) ? va_q[38:30] : (level_q == 2'd1) ? va_q[29:21] : va_q[20:12];
    wire [55:0] pte_addr = {base_q, vpn_cur, 3'b000};

    wire pmp_r_ok;
    /* verilator lint_off PINCONNECTEMPTY */
    qv_pmp pmp0 (
        .i_pmpcfg0(i_pmpcfg0), .i_pmpaddr0(i_pmpaddr0), .i_pmpaddr1(i_pmpaddr1), .i_pmpaddr2(i_pmpaddr2), .i_pmpaddr3(i_pmpaddr3),
        .i_addr({8'b0, pte_addr}), .i_end({8'b0, pte_addr} + 64'd7), .i_priv(2'b01),
        .o_read_ok(pmp_r_ok), .o_write_ok(), .o_exec_ok()
    );
    /* verilator lint_on PINCONNECTEMPTY */
    wire pmp_deny = !pmp_r_ok;

    // F's beat outside the RAM window waits for the real path (see the header)
    /* verilator lint_off UNSIGNED */
    wire pte_in_ram = (PMA_RAM_SIZE == 64'd0)
                      || (({8'b0, pte_addr} >= PMA_RAM_BASE) && (({8'b0, pte_addr} - PMA_RAM_BASE) < PMA_RAM_SIZE)
                          && (pte_addr[55:32] == 24'b0));
    /* verilator lint_on UNSIGNED */
    wire f_wait  = cl_q && !pte_in_ram && !i_f_nonspec;

    // in W_GO a stale walk and a PMP denial are handled before a beat is considered (see the case below), so
    // a cancel in the cycle a beat would start means no beat
    wire go_beat = (st_q == W_GO) && !i_lsu_busy && !f_wait;

    wire resp = beat_q && (i_bus_ack || i_bus_err);
    assign o_bus_cyc  = beat_q && !(i_bus_ack || i_bus_err);
    assign o_bus_addr = {pte_addr[31:3], 3'b000};
    assign o_beat     = beat_q;

    // ---------------- judging the PTE that came back ----------------
    wire        pte_leaf, pte_fault;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [43:0] pte_ppn_unused;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [43:0] pte_next_ppn;
    qv_pte pte0 (
        .i_pte(pte_q), .i_va(va_q), .i_level(level_q), .i_is_mem(is_mem_q), .i_wr(wr_q), .i_priv(priv_q),
        .i_sum(sum_q), .i_mxr(mxr_q),
        .o_leaf(pte_leaf), .o_fault(pte_fault), .o_ppn(pte_ppn_unused), .o_next_ppn(pte_next_ppn)
    );

    // ---------------- the walk ----------------
    // what ends a walk this cycle, and how
    logic rep_any, rep_ok, rep_pf, rep_af;
    always_comb begin
        rep_any = 1'b0; rep_ok = 1'b0; rep_pf = 1'b0; rep_af = 1'b0;
        if (st_q == W_GO && !stale_eff && pmp_deny) begin
            rep_any = 1'b1; rep_af = 1'b1;                  // the PTE read is denied: it never reaches the bus
        end
        if (st_q == W_DEC && !stale_eff) begin
            if (err_q) begin
                rep_any = 1'b1; rep_af = 1'b1;
            end else if (pte_fault) begin
                rep_any = 1'b1; rep_pf = 1'b1;
            end else if (pte_leaf) begin
                rep_any = 1'b1; rep_ok = 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            st_q     <= W_IDLE;
            cl_q     <= 1'b0;
            stale_q  <= 1'b0;
            beat_q   <= 1'b0;
            d_done_q <= 1'b0;
            f_done_q <= 1'b0;
        end else begin
            d_done_q <= 1'b0;
            f_done_q <= 1'b0;
            if (st_q != W_IDLE && cancel_srv) stale_q <= 1'b1;
            case (st_q)
                W_IDLE: begin
                    if (accept_d || accept_f) begin
                        cl_q     <= accept_f;
                        stale_q  <= 1'b0;
                        va_q     <= accept_f ? i_f_va : i_d_va;
                        base_q   <= accept_f ? i_f_root : i_d_root;
                        level_q  <= 2'd2;
                        is_mem_q <= accept_d;
                        wr_q     <= accept_d && i_d_wr;
                        priv_q   <= accept_f ? i_f_priv : i_d_priv;
                        sum_q    <= accept_d && i_d_sum;
                        mxr_q    <= accept_d && i_d_mxr;
                        st_q     <= W_GO;
                    end
                end
                W_GO: begin
                    if (stale_eff) begin                    // nothing in flight: just stop
                        stale_q <= 1'b0;
                        st_q    <= W_IDLE;
                    end else if (pmp_deny) begin
                        st_q    <= W_IDLE;                  // reported below
                    end else if (f_wait && d_can) begin     // D's walk goes first; F is accepted again after it
                        st_q    <= W_IDLE;
                    end else if (go_beat) begin
                        beat_q <= 1'b1;
                        st_q   <= W_BEAT;
                    end
                end
                W_BEAT: begin
                    if (resp) begin
                        beat_q <= 1'b0;
                        pte_q  <= i_bus_dat;
                        err_q  <= i_bus_err;
                        st_q   <= W_DEC;
                    end
                end
                default: begin                              // W_DEC
                    if (stale_eff) begin                    // the beat finished, its result is not wanted
                        stale_q <= 1'b0;
                        st_q    <= W_IDLE;
                    end else if (rep_any) begin
                        st_q    <= W_IDLE;                  // reported below
                    end else begin                          // a pointer: one level down
                        level_q <= level_q - 2'd1;
                        base_q  <= pte_next_ppn;
                        st_q    <= W_GO;
                    end
                end
            endcase

            if (rep_any) begin
                res_ok_q    <= rep_ok;
                res_pf_q    <= rep_pf;
                res_af_q    <= rep_af;
                res_vpn_q   <= va_q[38:12];
                res_level_q <= level_q;
                res_ppn_q   <= pte_q[53:10];
                res_r_q     <= pte_q[1];
                res_w_q     <= pte_q[2];
                res_x_q     <= pte_q[3];
                res_u_q     <= pte_q[4];
                res_d_q     <= pte_q[7];
                if (cl_q) f_done_q <= 1'b1; else d_done_q <= 1'b1;
            end
        end
    end

    assign o_d_done    = d_done_q;
    assign o_f_done    = f_done_q;
    assign o_res_ok    = res_ok_q;
    assign o_res_pf    = res_pf_q;
    assign o_res_af    = res_af_q;
    assign o_res_vpn   = res_vpn_q;
    assign o_res_level = res_level_q;
    assign o_res_ppn   = res_ppn_q;
    assign o_res_r     = res_r_q;
    assign o_res_w     = res_w_q;
    assign o_res_x     = res_x_q;
    assign o_res_u     = res_u_q;
    assign o_res_d     = res_d_q;
endmodule
