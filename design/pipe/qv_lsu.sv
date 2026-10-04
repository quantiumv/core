// SPDX-License-Identifier: MIT

/*
 * qv_lsu -- the load/store unit: one memory op at a time, performed only
 * once it is the ROB head (so it is no longer speculative, and an MMIO
 * access happens exactly once).
 *
 *   IDLE       slot free (o_free); issue may dispatch a memory uop
 *   WAIT_HEAD  holding one; the address and everything derived from it
 *              were computed at dispatch. A flush drops it.
 *   BUS        Wishbone request in flight
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
 * Request encoding (from issue): op[3:0] = {is_store, signed, size}, a =
 * rs1, b = rs2 (store data) or the I-immediate (loads), imm = the
 * S-immediate. The address is a + imm for stores, a + b for loads.
 *
 * o_head_started is for interrupts and debug halt (P5 on): once the head's
 * access has started they must wait for it to retire, because a store or
 * an MMIO read can't be undone.
 */
module qv_lsu (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             i_flush,

    // is_word, pc, rvc and pred_next don't apply to memory ops
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::fu_req_t                  i_req,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic                             o_free,

    input  logic                             i_head_valid,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_head_tag,

    output logic [31:0]                      wb_mem_addr_o,
    output logic [63:0]                      wb_mem_dat_o,
    output logic [7:0]                       wb_mem_sel_o,
    output logic                             wb_mem_we_o,
    output logic                             wb_mem_cyc_o,
    output logic                             wb_mem_stb_o,
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
    logic [63:0]             addr_q, wdata_q;
    logic [7:0]              sel_q;
    logic [1:0]              size_q;
    logic                    store_q, signed_q, misaligned_q;

    // ---------------- at dispatch ----------------
    wire        req_store  = i_req.op[3];
    wire [1:0]  req_size   = i_req.op[1:0];
    wire [63:0] req_addr   = i_req.a + (req_store ? i_req.imm : i_req.b);
    wire [7:0]  size_mask  = (req_size == 2'd0) ? 8'h01 : (req_size == 2'd1) ? 8'h03
                           : (req_size == 2'd2) ? 8'h0F : 8'hFF;
    wire        req_misaligned = (req_size == 2'd1) ? req_addr[0]
                               : (req_size == 2'd2) ? (req_addr[1:0] != 2'd0)
                               : (req_size == 2'd3) ? (req_addr[2:0] != 3'd0) : 1'b0;
    wire        accept     = (state_q == S_IDLE) && i_req.valid && !i_flush;

    // ---------------- at the head ----------------
    wire at_head = (state_q == S_WAIT_HEAD) && i_head_valid && (i_head_tag == tag_q) && !i_flush;
    wire start   = at_head && !misaligned_q;
    wire resp    = wb_mem_ack_i || wb_mem_err_i;
    wire in_bus  = (state_q == S_BUS) || (state_q == S_DRAIN);

    assign wb_mem_cyc_o  = (start || in_bus) && !resp;
    assign wb_mem_stb_o  = wb_mem_cyc_o;
    assign wb_mem_addr_o = {addr_q[31:3], 3'b000};
    assign wb_mem_dat_o  = wdata_q;
    assign wb_mem_sel_o  = sel_q;
    assign wb_mem_we_o   = store_q;

    assign o_free         = (state_q == S_IDLE);
    assign o_head_started = start || in_bus;

    // A response in the start cycle can't happen (every slave answers a
    // cycle later at the earliest), so completion is only from BUS.
    wire done_bus  = (state_q == S_BUS) && resp;
    wire done_mis  = at_head && misaligned_q;

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

    always_comb begin
        o_wb       = '0;
        o_wb.valid = done_bus || done_mis;
        o_wb.tag   = tag_q;
        o_wb.value = (done_bus && !wb_mem_err_i && !store_q) ? load_value : 64'b0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= S_IDLE;
            o_res   <= '0;
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
                    signed_q     <= i_req.op[2];
                    misaligned_q <= req_misaligned;
                end
                S_WAIT_HEAD: begin
                    if (i_flush)      state_q <= S_IDLE;
                    else if (start)   state_q <= S_BUS;
                    else if (done_mis) state_q <= S_IDLE;
                end
                S_BUS:   if (resp) state_q <= S_IDLE;
                         else if (i_flush) state_q <= S_DRAIN;
                S_DRAIN: if (resp) state_q <= S_IDLE;
                default: state_q <= S_IDLE;
            endcase

            if (done_bus || done_mis) begin
                o_res           <= '0;
                o_res.xcpt      <= done_mis || wb_mem_err_i;
                o_res.cause     <= done_mis ? (store_q ? 4'd6 : 4'd4) : (store_q ? 4'd7 : 4'd5);
                o_res.tval      <= addr_q;
                o_res.mem_addr  <= {addr_q[63:3], 3'b000};
                o_res.mem_rmask <= store_q ? 8'b0 : sel_q;
                o_res.mem_wmask <= store_q ? sel_q : 8'b0;
                o_res.mem_rdata <= done_bus ? wb_mem_dat_i : 64'b0;
                o_res.mem_wdata <= wdata_q;
            end
        end
    end
endmodule
