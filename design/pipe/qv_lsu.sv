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
 * touches the bus; otherwise the request goes out that same cycle. On
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
 * o_head_started is for interrupts and debug halt (P5 on): once the head's
 * access has started they must wait for it to retire, because a store or
 * an MMIO read can't be undone.
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
    output logic                             o_head_started
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
    wire sc_fail  = sc_q && !(i_res_valid && i_res_addr == addr_q);
    wire start    = at_head && !misaligned_q && !sc_fail;
    wire resp     = wb_mem_ack_i || wb_mem_err_i;
    wire in_bus   = (state_q == S_BUS) || (state_q == S_DRAIN);

    assign wb_mem_cyc_o  = (start || in_bus) && !resp;
    assign wb_mem_stb_o  = wb_mem_cyc_o;
    assign wb_mem_addr_o = {addr_q[31:3], 3'b000};
    assign wb_mem_sel_o  = sel_q;
    assign wb_mem_we_o   = store_q || phase_wr_q;
    assign wb_mem_lock_o = amo_q && (start || in_bus);

    // an AMO's write data: old OP rs2, computed from registers
    wire [63:0] b_amo     = wdata_q >> {addr_q[2:0], 3'b000};
    wire [63:0] amo_wdata = amo_result(aop_q, word_q, old_q, b_amo) << {addr_q[2:0], 3'b000};
    assign wb_mem_dat_o   = phase_wr_q ? amo_wdata : wdata_q;

    assign o_free         = (state_q == S_IDLE);
    assign o_head_started = start || in_bus;

    // A response in the start cycle can't happen (every slave answers a
    // cycle later at the earliest), so bus completion is only from BUS.
    // An AMO's first (read) response doesn't complete it: the write follows.
    wire amo_read_ack = (state_q == S_BUS) && amo_q && !phase_wr_q && wb_mem_ack_i && !wb_mem_err_i && !i_flush;
    wire done_bus     = (state_q == S_BUS) && resp && !amo_read_ack;
    wire done_nobus   = at_head && (misaligned_q || sc_fail);     // misaligned, or SC without its reservation

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

    wire sc_fail_done = done_nobus && !misaligned_q;               // SC without its reservation: rd = 1
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
                end
                S_WAIT_HEAD: begin
                    if (i_flush)         state_q <= S_IDLE;
                    else if (start)      state_q <= S_BUS;
                    else if (done_nobus) state_q <= S_IDLE;
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
                    o_res.cause     <= done_nobus ? (fault_st ? 4'd6 : 4'd4) : (fault_st ? 4'd7 : 4'd5);
                    o_res.tval      <= addr_q;
                    o_res.vaddr     <= addr_q;
                    o_res.mem_addr  <= {addr_q[63:3], 3'b000};
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
