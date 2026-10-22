// SPDX-License-Identifier: MIT

/*
 * qv_lsu -- the load/store unit: one memory op at a time, performed only
 * once it is the ROB head (so it is no longer speculative, and an MMIO
 * access happens exactly once). Loads, stores and the A extension.
 *
 *   IDLE       slot free (o_free); issue may dispatch a memory uop
 *   WAIT_HEAD  holding one; the address and everything derived from it
 *              were computed at dispatch. A flush drops it.
 *   BUS        Wishbone request in flight (an AMO's read, then its write)
 *   DRAIN      flushed while in flight: the request is never abandoned
 *              (dropping cyc early would let wb_arbiter2 hand the late ack
 *              to the other master), so wait for its ack/err and discard
 *
 * When the uop becomes the head: a misaligned access (natural alignment
 * per size; bytes never are) completes at once with cause 4/6 and never
 * touches the bus; so does one the PMP denies (cause 5 for a load, 7 for
 * everything that writes -- LR and the AMOs too -- see below); otherwise
 * the request goes out that same cycle. On
 * ack/err the uop completes on the slow writeback port and the slot is
 * free from the next cycle -- freeing it any later would let it re-issue
 * the access while the uop sits completed at the head. err is checked
 * before ack (the caches raise both): cause 5/7. tval is the exact access
 * address. cyc/stb drop combinationally in the ack/err cycle, as core.sv
 * does, so a slave that re-samples requests in its response cycle never
 * sees a second one.
 *
 * Everything commit needs beyond the value -- the exception and the RVFI
 * memory fields -- is held in o_res until the next memory op completes;
 * only the head ever sits between completion and commit. Formats follow
 * core.sv: bus addr {a[31:3],000} (bits 63:32 dropped), sel = size mask
 * << a[2:0], store data b << a[2:0]*8 unmasked, load data shifted down
 * then sign/zero-extended; RVFI addr {a[63:3],000}, masks = sel, rdata the
 * raw bus word, wdata the shifted b.
 *
 * Request encoding (from issue): op[4] = 0: op[3:0] = {is_store, signed,
 * size}, a = rs1, b = rs2 (store data) or the I-immediate (loads), imm =
 * the S-immediate; the address is a + imm for stores, a + b for loads.
 * op[4] = 1: an atomic, op[3:0] a qv_amo_op_e, is_word for .W (else .D),
 * a = rs1 = the address, b = rs2. Atomics are always sign-extended.
 *
 * Atomics follow core.sv exactly, including its choices:
 *   - LR is a load, SC a store, the AMOs a read then a write; but all of
 *     them are in the store class for faults: misaligned is cause 6 and a
 *     bus error cause 7, whatever the phase (so LR faults like a store).
 *   - SC compares the reservation (held by commit, passed in) with its own
 *     address, a full 64-bit equality, in the cycle it becomes the head:
 *     everything older has committed by then and nothing else can change
 *     it. A match is an ordinary store that writes rd = 0; no match is a
 *     completion with rd = 1 and no bus access at all. A misaligned SC
 *     faults either way.
 *   - an AMO reads, then writes old OP rs2 (the .W forms work on the
 *     sign-extended low halves and sign-extend the result) with wb_mem_lock_o
 *     held from its read request through its write's response cycle, so the
 *     arbiter can't hand the bus to the other master in between. rd gets
 *     the old value. The write data is computed from registers, not from
 *     the bus input, which keeps wb_mem_dat_i out of that path.
 *   - an AMO's RVFI memory fields: both masks set, rdata the extracted old
 *     value, wdata the new value in its lane. A failed SC reports none.
 *
 * PMP (qv_pmp, a literal copy of core.sv's check): the access itself,
 * [addr, addr + size - 1], is checked at the effective privilege -- M runs
 * at MPP while mstatus.MPRV is set -- once it is the head. Loads need R;
 * stores, SC, LR and AMOs need W. Priority: misaligned, then the PMP, then
 * the SC's reservation compare.
 *
 * o_head_started says the head's access is under way. An interrupt never
 * needs to wait for it: it is taken only in the cycle after a retirement,
 * when nothing can be on the bus (core_pipe asserts this).
 *
 * Sv39 (P7c): with satp.MODE = Sv39, a privilege below M (the effective one:
 * MPRV applies) and no Program Buffer run, the head's address is translated
 * after the checks that need no physical address and before the PMP:
 *   misaligned          -> cause 4/6, no walk
 *   a failing SC        -> rd = 1, no walk, no PMP check (in Bare it still meets the PMP first)
 *   the translation     -> page fault: cause 13 for a load or LR, 15 for a store, SC or AMO (kind_wr);
 *                          access fault (PTE read denied or failed): 5/7 like any access fault of the class
 *   the PMP, on the physical address, at the effective privilege
 * The request goes out through o_xl_* to a qv_xlate (a held request, answered combinationally from
 * it), and the answer is registered (pa_q), so no TLB-to-PMP-to-bus path exists. An AMO is translated
 * once and its write phase reuses the address. tval, vaddr and the reservation stay on the virtual
 * address; the bus, the PMP and RVFI's memory address use the physical one. A flush while the
 * translation is pending cancels it (cannot happen in the real core: flushes only come in the cycle
 * after a retirement, when nothing waits, but the formal harness drives it freely).
 * The walker shares the memory port: i_ptw_beat (a PTE read of its in flight) keeps the LSU off the
 * bus, and o_bus_busy (an access started, or ready to start this cycle) keeps the walker off it.
 */
module qv_lsu (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             i_flush,

    // pc, rvc, imm (atomics) and pred_next don't apply
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::fu_req_t                  i_req,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic                             o_free,

    input  logic                             i_head_valid,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_head_tag,

    // LR/SC reservation, kept by commit
    input  logic                             i_res_valid,
    input  logic [63:0]                      i_res_addr,

    // PMP: the privilege commit keeps, mstatus.MPRV/MPP (data accesses only: an M-mode access runs
    // at MPP when MPRV is set) and csr_file0's PMP exports; the defaults are the reset state
    input  logic [1:0]                       i_priv = 2'b11,
    input  logic                             i_mprv = 1'b0,
    input  logic [1:0]                       i_mpp  = 2'b11,
    // a Program Buffer run is trusted: no PMP check on its data accesses
    input  logic                             i_pmp_bypass = 1'b0,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]                      i_pmpcfg0  = 64'h0000_0000_0000_001F,
    input  logic [63:0]                      i_pmpaddr0 = 64'h003F_FFFF_FFFF_FFFF,
    input  logic [63:0]                      i_pmpaddr1 = 64'b0,
    input  logic [63:0]                      i_pmpaddr2 = 64'b0,
    input  logic [63:0]                      i_pmpaddr3 = 64'b0,
    /* verilator lint_on UNUSEDSIGNAL */

    output logic [31:0]                      wb_mem_addr_o,
    output logic [63:0]                      wb_mem_dat_o,
    output logic [7:0]                       wb_mem_sel_o,
    output logic                             wb_mem_we_o,
    output logic                             wb_mem_cyc_o,
    output logic                             wb_mem_stb_o,
    output logic                             wb_mem_lock_o,
    input  logic [63:0]                      wb_mem_dat_i,
    input  logic                             wb_mem_ack_i,
    input  logic                             wb_mem_err_i,

    output qv_pkg::wb_t                      o_wb,
    output qv_pkg::lsu_res_t                 o_res,
    output logic                             o_head_started,

    // Sv39: satp.MODE is Sv39 (csr_file0's satp[63:60] == 8)
    input  logic                             i_satp_on = 1'b0,
    // the translation request (see the header); o_xl_active and o_xl_priv are the context it is judged in
    output logic                             o_xl_req,
    output logic [63:0]                      o_xl_va,
    output logic                             o_xl_wr,
    output logic                             o_xl_active,
    output logic [1:0]                       o_xl_priv,
    output logic                             o_xl_cancel,
    input  logic                             i_xl_done = 1'b0,
    input  logic                             i_xl_pf = 1'b0,
    input  logic                             i_xl_af = 1'b0,
    input  logic [43:0]                      i_xl_ppn = 44'b0,
    // sharing the memory port with the walker
    input  logic                             i_ptw_beat = 1'b0,
    output logic                             o_bus_busy
);
    import qv_pkg::*;

    typedef enum logic [1:0] { S_IDLE, S_WAIT_HEAD, S_BUS, S_DRAIN } state_e;
    state_e state_q;

    logic [QV_ROB_TAG_W-1:0] tag_q;
    logic [63:0]             addr_q, wdata_q, old_q;
    logic [7:0]              sel_q;
    logic [1:0]              size_q;
    logic                    store_q, signed_q, misaligned_q;
    logic                    atomic_q, phase_wr_q;      // phase_wr_q: an AMO's write has begun
    qv_amo_op_e              aop_q;

    // ---------------- at dispatch ----------------
    wire        req_atomic  = i_req.op[4];
    wire        req_is_sc   = req_atomic && (qv_amo_op_e'(i_req.op[3:0]) == QV_AMO_SC);
    wire        req_plain_store = !req_atomic && i_req.op[3];
    wire        req_store   = req_plain_store || req_is_sc;       // a bus write (SC: if it holds)
    wire [1:0]  req_size    = req_atomic ? (i_req.is_word ? 2'd2 : 2'd3) : i_req.op[1:0];
    wire        req_signed  = req_atomic || i_req.op[2];
    wire [63:0] req_addr    = req_atomic ? i_req.a : i_req.a + (req_plain_store ? i_req.imm : i_req.b);
    wire [7:0]  size_mask   = (req_size == 2'd0) ? 8'h01 : (req_size == 2'd1) ? 8'h03
                            : (req_size == 2'd2) ? 8'h0F : 8'hFF;
    wire        req_misaligned = (req_size == 2'd1) ? req_addr[0]
                               : (req_size == 2'd2) ? (req_addr[1:0] != 2'd0)
                               : (req_size == 2'd3) ? (req_addr[2:0] != 3'd0) : 1'b0;
    wire        accept      = (state_q == S_IDLE) && i_req.valid && !i_flush;

    // ---------------- what the held op is ----------------
    wire lr_q      = atomic_q && (aop_q == QV_AMO_LR);
    wire sc_q      = atomic_q && (aop_q == QV_AMO_SC);
    wire amo_q     = atomic_q && !lr_q && !sc_q;                  // read-modify-write
    wire word_q    = (size_q == 2'd2);
    wire kind_rd   = atomic_q ? !sc_q : !store_q;                 // reads memory: loads, LR, AMOs
    wire kind_wr   = atomic_q ? !lr_q : store_q;                  // writes it: stores, SC, AMOs
    wire fault_st  = store_q || atomic_q;                         // faults like a store: cause 6/7

    // ---------------- at the head ----------------
    wire at_head  = (state_q == S_WAIT_HEAD) && i_head_valid && (i_head_tag == tag_q) && !i_flush;
    wire sc_fail  = sc_q && !(i_res_valid && i_res_addr == addr_q);      // the reservation is a virtual address

    // ---------------- translation ----------------
    // On for a privilege below M (the effective one: M runs at MPP while MPRV is set), a Program Buffer
    // run excepted, when satp says Sv39. Constant while the op waits: every change of any of it
    // flushes. A misaligned access and a failing SC (under translation) complete without it.
    wire [1:0]  eff_priv = (i_mprv && i_priv == 2'b11) ? i_mpp : i_priv;
    wire        xl_on    = i_satp_on && !i_pmp_bypass && (eff_priv != 2'b11);
    logic       xlated_q;                  // the translation is in: pa_q holds the physical address
    logic [63:0] pa_q;
    wire        pa_valid = !xl_on || xlated_q;
    wire [63:0] pa       = xl_on ? pa_q : addr_q;

    wire x_req   = at_head && xl_on && !misaligned_q && !sc_fail && !xlated_q;
    wire x_fault = x_req && i_xl_done && (i_xl_pf || i_xl_af);
    wire x_ok    = x_req && i_xl_done && !i_xl_pf && !i_xl_af;
    assign o_xl_req    = x_req;
    assign o_xl_va     = addr_q;
    assign o_xl_wr     = kind_wr;           // a store, SC or AMO needs W and D; a load or LR does not
    assign o_xl_active = xl_on;
    assign o_xl_priv   = eff_priv;
    assign o_xl_cancel = (state_q == S_WAIT_HEAD) && i_flush && xl_on && !xlated_q;

    // ---------------- PMP ----------------
    // checked against the access itself, [pa, pa + size - 1], once it is the head and (under
    // translation) translated; loads need R, everything that writes (stores, SC, and LR and AMOs
    // too, as core.sv has it) needs W; a misaligned access traps first, and a PMP fault comes before
    // the SC's reservation compare -- but under translation a failing SC never meets the PMP
    wire [63:0] end_addr = pa + (64'd1 << size_q) - 64'd1;
    logic       pmp_r_ok, pmp_w_ok;
    /* verilator lint_off PINCONNECTEMPTY */
    qv_pmp pmp0 (
        .i_pmpcfg0(i_pmpcfg0), .i_pmpaddr0(i_pmpaddr0), .i_pmpaddr1(i_pmpaddr1),
        .i_pmpaddr2(i_pmpaddr2), .i_pmpaddr3(i_pmpaddr3),
        .i_addr(pa), .i_end(end_addr), .i_priv(eff_priv),
        .o_read_ok(pmp_r_ok), .o_write_ok(pmp_w_ok), .o_exec_ok()
    );
    /* verilator lint_on PINCONNECTEMPTY */
    wire pmp_deny = !misaligned_q && !i_pmp_bypass && pa_valid && !(xl_on && sc_fail)
                    && !(fault_st ? pmp_w_ok : pmp_r_ok);

    wire start_raw = at_head && !misaligned_q && !pmp_deny && !sc_fail && pa_valid;
    wire start     = start_raw && !i_ptw_beat;
    wire resp     = wb_mem_ack_i || wb_mem_err_i;
    wire in_bus   = (state_q == S_BUS) || (state_q == S_DRAIN);

    assign wb_mem_cyc_o  = (start || in_bus) && !resp;
    assign wb_mem_stb_o  = wb_mem_cyc_o;
    assign wb_mem_addr_o = {pa[31:3], 3'b000};
    assign wb_mem_sel_o  = sel_q;
    assign wb_mem_we_o   = store_q || phase_wr_q;
    assign wb_mem_lock_o = amo_q && (start || in_bus);

    // an AMO's write data: old OP rs2, computed from registers
    wire [63:0] b_amo     = wdata_q >> {addr_q[2:0], 3'b000};
    wire [63:0] amo_wdata = amo_result(aop_q, word_q, old_q, b_amo) << {addr_q[2:0], 3'b000};
    assign wb_mem_dat_o   = phase_wr_q ? amo_wdata : wdata_q;

    assign o_free         = (state_q == S_IDLE);
    assign o_head_started = start || in_bus;
    assign o_bus_busy     = start_raw || in_bus;           // the walker waits while this is high

    // A response in the start cycle can't happen (every slave answers a
    // cycle later at the earliest), so bus completion is only from BUS.
    // An AMO's first (read) response doesn't complete it: the write follows.
    wire amo_read_ack = (state_q == S_BUS) && amo_q && !phase_wr_q && wb_mem_ack_i && !wb_mem_err_i && !i_flush;
    wire done_bus     = (state_q == S_BUS) && resp && !amo_read_ack;
    wire done_nobus   = at_head && (misaligned_q || pmp_deny || sc_fail || x_fault);   // trapped before the bus, or SC without its reservation

    // load data: shift the addressed bytes down, then extend
    wire [63:0] shifted = wb_mem_dat_i >> {addr_q[2:0], 3'b000};
    logic [63:0] load_value;
    always_comb begin
        case (size_q)
            2'd0:    load_value = signed_q ? {{56{shifted[7]}},  shifted[7:0]}  : {56'b0, shifted[7:0]};
            2'd1:    load_value = signed_q ? {{48{shifted[15]}}, shifted[15:0]} : {48'b0, shifted[15:0]};
            2'd2:    load_value = signed_q ? {{32{shifted[31]}}, shifted[31:0]} : {32'b0, shifted[31:0]};
            default: load_value = shifted;
        endcase
    end

    // old OP rs2, as the ALU does it in core.sv: SWAP passes rs2, the .W
    // forms use the sign-extended low halves and extend the result back
    function automatic logic [63:0] amo_result(input qv_amo_op_e op, input logic word,
                                               input logic [63:0] old, input logic [63:0] rs2);
        logic [63:0] b, r;
        b = word ? {{32{rs2[31]}}, rs2[31:0]} : rs2;
        case (op)
            QV_AMO_SWAP: r = b;
            QV_AMO_ADD:  r = old + b;
            QV_AMO_XOR:  r = old ^ b;
            QV_AMO_AND:  r = old & b;
            QV_AMO_OR:   r = old | b;
            QV_AMO_MIN:  r = ($signed(old) < $signed(b)) ? old : b;
            QV_AMO_MAX:  r = ($signed(old) < $signed(b)) ? b : old;
            QV_AMO_MINU: r = (old < b) ? old : b;
            QV_AMO_MAXU: r = (old < b) ? b : old;
            default:     r = b;
        endcase
        return word ? {{32{r[31]}}, r[31:0]} : r;
    endfunction

    wire sc_fail_done = at_head && sc_fail && !misaligned_q && !pmp_deny; // SC without its reservation: rd = 1
    always_comb begin
        o_wb       = '0;
        o_wb.valid = done_bus || done_nobus;
        o_wb.tag   = tag_q;
        if (sc_fail_done)                             o_wb.value = 64'd1;
        else if (done_bus && !wb_mem_err_i && amo_q)  o_wb.value = old_q;
        else if (done_bus && !wb_mem_err_i && kind_rd && !sc_q) o_wb.value = load_value;
        else                                          o_wb.value = 64'b0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q    <= S_IDLE;
            phase_wr_q <= 1'b0;
            xlated_q   <= 1'b0;
            o_res      <= '0;
        end else begin
            case (state_q)
                S_IDLE: if (accept) begin
                    state_q      <= S_WAIT_HEAD;
                    tag_q        <= i_req.tag;
                    addr_q       <= req_addr;
                    wdata_q      <= i_req.b << {req_addr[2:0], 3'b000};
                    sel_q        <= size_mask << req_addr[2:0];
                    size_q       <= req_size;
                    store_q      <= req_store;
                    signed_q     <= req_signed;
                    misaligned_q <= req_misaligned;
                    atomic_q     <= req_atomic;
                    aop_q        <= qv_amo_op_e'(i_req.op[3:0]);
                    phase_wr_q   <= 1'b0;
                    xlated_q     <= 1'b0;
                end
                S_WAIT_HEAD: begin
                    if (i_flush)         state_q <= S_IDLE;
                    else if (start)      state_q <= S_BUS;
                    else if (done_nobus) state_q <= S_IDLE;
                    else if (x_ok) begin                      // translated: the physical address, checked and used from the next cycle
                        pa_q     <= {8'b0, i_xl_ppn, addr_q[11:0]};
                        xlated_q <= 1'b1;
                    end
                end
                S_BUS: begin
                    if (amo_read_ack) begin
                        phase_wr_q <= 1'b1;               // stay in BUS: the write request follows
                        old_q      <= load_value;
                    end else if (resp) begin
                        state_q <= S_IDLE;
                    end else if (i_flush) begin
                        state_q <= S_DRAIN;
                    end
                end
                S_DRAIN: if (resp) state_q <= S_IDLE;
                default: state_q <= S_IDLE;
            endcase

            if (done_bus || done_nobus) begin
                o_res        <= '0;
                // an SC without its reservation did nothing: no fields at all
                if (!sc_fail_done) begin
                    o_res.xcpt      <= done_nobus || wb_mem_err_i;
                    // misaligned: 4/6; a page fault from the translation: 13 (load, LR) or 15 (store, SC, AMO); a PMP
                    // denial, a failed PTE read or a bus error: 5/7 (stores, SC, LR, AMOs: the odd ones)
                    o_res.cause     <= (done_nobus && misaligned_q) ? (fault_st ? 4'd6 : 4'd4)
                                     : (x_fault && i_xl_pf)         ? (kind_wr ? 4'd15 : 4'd13)
                                     :                                (fault_st ? 4'd7 : 4'd5);
                    o_res.tval      <= addr_q;
                    o_res.vaddr     <= addr_q;
                    o_res.mem_addr  <= {(pa_valid ? pa[63:3] : addr_q[63:3]), 3'b000};
                    o_res.mem_rmask <= kind_rd ? sel_q : 8'b0;
                    o_res.mem_wmask <= kind_wr ? sel_q : 8'b0;
                    o_res.mem_rdata <= (done_bus && amo_q && phase_wr_q) ? old_q
                                     : done_bus ? wb_mem_dat_i : 64'b0;
                    o_res.mem_wdata <= (amo_q && phase_wr_q) ? amo_wdata : wdata_q;
                end
            end
        end
    end
endmodule
