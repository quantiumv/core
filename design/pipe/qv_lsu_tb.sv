// SPDX-License-Identifier: MIT

/*
 * qv_lsu_tb -- standalone test for design/pipe/qv_lsu.sv.
 *
 * A Wishbone slave model with random wait states checks the protocol on
 * every cycle -- a request stays stable until its response, cyc drops in
 * the ack/err cycle, nothing reaches the bus before the uop is the ROB
 * head, no access is ever issued twice -- and a golden memory model checks
 * every load's value and every store's effect, for every size, offset and
 * sign. Also: misaligned accesses (no bus, cause 4/6), bus errors (5/7,
 * including err raised together with ack), the RVFI fields in o_res, the
 * slot freeing at the response edge, a flush while waiting (dropped) and a
 * flush while in flight (never abandoned, result discarded).
 *
 * The A extension: LR, SC (with and without its reservation, misaligned,
 * faulting), and all nine AMOs in both widths against an independently
 * written golden model -- read value, written value, rd, the RVFI fields;
 * the read-then-write sequence on the bus (exactly two accesses, same
 * address, the write after the read); wb_mem_lock_o up from the first
 * request cycle through the write's response cycle with no gap, and never
 * for anything that isn't an AMO; a write-phase bus error; a flush while
 * an AMO's read is in flight (no write follows).
 *
 * PMP: loads need R and everything that writes (stores, SC, LR, AMOs) needs
 * W, checked on the access's own span [addr, addr + size - 1] at the
 * effective privilege (M runs at MPP when MPRV is set); a denial is cause
 * 5/7 with the address as tval, no bus access, the would-be RVFI fields; a
 * misaligned access still traps first (4/6) and an SC is judged by the PMP
 * before its reservation.
 */
module qv_lsu_tb;
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic                    flush = 1'b0;
    fu_req_t                 req = '0;
    logic                    free;
    logic                    head_valid = 1'b0;
    logic [QV_ROB_TAG_W-1:0] head_tag = '0;
    logic [31:0]             addr;
    logic [63:0]             dat_o, dat_i;
    logic [7:0]              sel;
    logic                    we, cyc, stb, ack, err;
    wb_t                     wb;
    lsu_res_t                res;
    logic                    started;
    logic                    res_valid = 1'b0;
    logic [63:0]             res_addr  = '0;
    logic                    lock;
    // PMP state: the reset state (region 0 NAPOT over everything, rwx), M mode
    logic [1:0]              priv = 2'b11, mpp = 2'b11;
    logic                    mprv = 1'b0;
    logic                    pmp_bypass = 1'b0;      // a Program Buffer run: no PMP check on its data accesses
    logic [63:0]             pmpcfg0 = 64'h1F, pmpaddr0 = 64'h003F_FFFF_FFFF_FFFF, pmpaddr1 = '0, pmpaddr2 = '0, pmpaddr3 = '0;

    qv_lsu dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(req), .o_free(free),
        .i_head_valid(head_valid), .i_head_tag(head_tag),
        .i_res_valid(res_valid), .i_res_addr(res_addr),
        .i_priv(priv), .i_mprv(mprv), .i_mpp(mpp), .i_pmp_bypass(pmp_bypass),
        .i_pmpcfg0(pmpcfg0), .i_pmpaddr0(pmpaddr0), .i_pmpaddr1(pmpaddr1),
        .i_pmpaddr2(pmpaddr2), .i_pmpaddr3(pmpaddr3),
        .wb_mem_addr_o(addr), .wb_mem_dat_o(dat_o), .wb_mem_sel_o(sel), .wb_mem_we_o(we),
        .wb_mem_cyc_o(cyc), .wb_mem_stb_o(stb), .wb_mem_lock_o(lock),
        .wb_mem_dat_i(dat_i), .wb_mem_ack_i(ack), .wb_mem_err_i(err),
        .o_wb(wb), .o_res(res), .o_head_started(started)
    );

    // ---------------- slave model ----------------
    localparam int WORDS = 64;                       // 512 bytes; anything above 0x800 errors
    logic [63:0] mem [0:WORDS-1];
    logic [63:0] gold [0:WORDS-1];
    int   wait_max = 0;
    logic err_with_ack = 1'b0;                       // raise ack together with err
    int   accesses = 0;                              // requests the slave accepted
    logic [31:0] werr_addr = 32'hFFFF_FFFF;          // a write to this address errors (reads there are fine)
    int   writes = 0;                                // write requests the slave accepted
    logic busy = 1'b0;
    int   wait_left;
    logic [31:0] h_addr; logic [63:0] h_dat; logic [7:0] h_sel; logic h_we;
    logic proto_ok = 1'b1;

    always @(posedge clk) begin
        ack <= 1'b0;
        err <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
        end else if (!busy && cyc && stb) begin
            busy <= 1'b1;
            h_addr <= addr; h_dat <= dat_o; h_sel <= sel; h_we <= we;
            wait_left <= (wait_max == 0) ? 0 : $urandom % (wait_max + 1);
            accesses <= accesses + 1;
            if (we) writes <= writes + 1;
        end else if (busy) begin
            if (!(cyc && stb) || addr != h_addr || sel != h_sel || we != h_we || (we && dat_o != h_dat)) begin
                if (proto_ok) $display("PROTO: request changed or dropped before its response");
                proto_ok <= 1'b0;
            end
            if (wait_left > 0) begin
                wait_left <= wait_left - 1;
            end else begin
                busy <= 1'b0;
                if (h_addr >= 32'h800 || (h_we && h_addr == werr_addr)) begin
                    err <= 1'b1;
                    ack <= err_with_ack;
                end else begin
                    ack <= 1'b1;
                    if (h_we)
                        for (int i = 0; i < 8; i++)
                            if (h_sel[i]) mem[h_addr[8:3]][8*i +: 8] <= h_dat[8*i +: 8];
                    dat_i <= mem[h_addr[8:3]];
                end
            end
        end
    end
    // cyc must be low in every response cycle (no request held into it)
    always @(negedge clk) begin
        if (!rst && (ack || err) && cyc) begin
            if (proto_ok) $display("PROTO: cyc still high in the response cycle");
            proto_ok = 1'b0;
        end
    end

    // ---------------- helpers ----------------
    logic [QV_ROB_TAG_W-1:0] next_tag = '0;

    function automatic logic [63:0] golden_load(input logic [63:0] a, input logic [1:0] size, input logic sgn);
        logic [63:0] w, s;
        w = gold[a[8:3]];
        s = w >> {a[2:0], 3'b000};
        case (size)
            2'd0:    return sgn ? {{56{s[7]}}, s[7:0]}   : {56'b0, s[7:0]};
            2'd1:    return sgn ? {{48{s[15]}}, s[15:0]} : {48'b0, s[15:0]};
            2'd2:    return sgn ? {{32{s[31]}}, s[31:0]} : {32'b0, s[31:0]};
            default: return w >> {a[2:0], 3'b000};
        endcase
    endfunction

    function automatic logic [7:0] golden_sel(input logic [63:0] a, input logic [1:0] size);
        logic [7:0] m;
        m = (size == 0) ? 8'h01 : (size == 1) ? 8'h03 : (size == 2) ? 8'h0F : 8'hFF;
        return m << a[2:0];
    endfunction

    function automatic logic misaligned(input logic [63:0] a, input logic [1:0] size);
        return (size == 1) ? a[0] : (size == 2) ? (a[1:0] != 0) : (size == 3) ? (a[2:0] != 0) : 1'b0;
    endfunction

    // dispatch one op; return its tag
    task automatic dispatch(input logic store, input logic [1:0] size, input logic sgn,
                            input logic [63:0] base, input logic [63:0] off, input logic [63:0] data,
                            output logic [QV_ROB_TAG_W-1:0] t);
        @(negedge clk);
        #1;
        check("dispatch: slot free", {63'b0, free}, 64'd1);
        t = next_tag;
        next_tag = next_tag + 1'b1;
        req       = '0;
        req.valid = 1'b1;
        req.tag   = t;
        req.op    = {1'b0, store, sgn, size};
        req.a     = base;
        req.b     = store ? data : off;
        req.imm   = store ? off : 64'hDEAD;              // loads must not use imm
        @(posedge clk); #1;
        req = '0;
    endtask

    // make t the head after `delay` cycles, wait for completion, check everything
    task automatic run_op(input string name, input logic store, input logic [1:0] size, input logic sgn,
                          input logic [63:0] base, input logic [63:0] off, input logic [63:0] data,
                          input int delay);
        logic [QV_ROB_TAG_W-1:0] t;
        logic [63:0] a, exp_v, exp_wdata;
        logic [7:0]  exp_sel;
        logic        mis, bad, got_wb;
        int          acc0, c;
        logic [63:0] wb_value;
        a   = base + off;
        mis = misaligned(a, size);
        bad = !mis && a[31:0] >= 32'h800;
        exp_sel   = golden_sel(a, size);
        exp_wdata = (store ? data : off) << {a[2:0], 3'b000};
        exp_v     = (!store && !mis && !bad) ? golden_load(a, size, sgn) : 64'b0;
        acc0 = accesses;
        dispatch(store, size, sgn, base, off, data, t);
        check({name, ": slot busy after dispatch"}, {63'b0, free}, 64'd0);
        // a different op at the head first: nothing may happen
        @(negedge clk);
        head_valid = 1'b1; head_tag = t + 1'b1;
        repeat (delay) begin
            @(posedge clk); #1;
            check({name, ": no bus before head"}, {63'b0, cyc}, 64'd0);
            check({name, ": no completion before head"}, {63'b0, wb.valid}, 64'd0);
        end
        @(negedge clk);
        head_tag = t;
        got_wb = 1'b0;
        for (c = 0; c < 50 && !got_wb; c++) begin
            #1;
            if (wb.valid) begin
                got_wb = 1'b1;
                wb_value = wb.value;
                check({name, ": wb tag"}, {60'b0, wb.tag}, {60'b0, t});
            end
            @(posedge clk);
        end
        #1;
        head_valid = 1'b0;
        check({name, ": completed"}, {63'b0, got_wb}, 64'd1);
        check({name, ": slot free at once"}, {63'b0, free}, 64'd1);
        check({name, ": bus accesses"}, 64'(accesses - acc0), mis ? 64'd0 : 64'd1);
        check({name, ": exception"}, {63'b0, res.xcpt}, {63'b0, mis || bad});
        if (mis)      check({name, ": cause"}, {60'b0, res.cause}, store ? 64'd6 : 64'd4);
        else if (bad) check({name, ": cause"}, {60'b0, res.cause}, store ? 64'd7 : 64'd5);
        if (mis || bad) check({name, ": tval = address"}, res.tval, a);
        check({name, ": rvfi addr"}, res.mem_addr, {a[63:3], 3'b000});
        check({name, ": rvfi rmask"}, {56'b0, res.mem_rmask}, store ? 64'd0 : {56'b0, exp_sel});
        check({name, ": rvfi wmask"}, {56'b0, res.mem_wmask}, store ? {56'b0, exp_sel} : 64'd0);
        check({name, ": rvfi wdata"}, res.mem_wdata, exp_wdata);
        if (!store) check({name, ": load value"}, wb_value, exp_v);
        if (store && !mis && !bad)
            for (int i = 0; i < 8; i++)
                if (exp_sel[i]) gold[a[8:3]][8*i +: 8] = exp_wdata[8*i +: 8];
        if (!mis && !bad && !store)
            check({name, ": rvfi rdata (raw word)"}, res.mem_rdata, gold[a[8:3]]);
    endtask

    // ---------------- atomics ----------------
    // The model of what an AMO computes, written separately from the RTL's:
    // the .W forms work on the 32-bit values (signed or unsigned compares at
    // 32 bits) and the result is the sign-extended low half.
    function automatic logic [63:0] golden_amo(input qv_amo_op_e op, input logic word,
                                               input logic [63:0] old, input logic [63:0] rs2);
        logic signed [63:0] so, sb;
        logic [63:0] ub, uo, r;
        if (word) begin
            so = $signed(old[31:0]);  sb = $signed(rs2[31:0]);
            uo = {32'b0, old[31:0]};  ub = {32'b0, rs2[31:0]};
        end else begin
            so = $signed(old);        sb = $signed(rs2);
            uo = old;                 ub = rs2;
        end
        case (op)
            QV_AMO_SWAP: r = 64'(sb);
            QV_AMO_ADD:  r = 64'(so + sb);
            QV_AMO_XOR:  r = 64'(so ^ sb);
            QV_AMO_AND:  r = 64'(so & sb);
            QV_AMO_OR:   r = 64'(so | sb);
            QV_AMO_MIN:  r = (so < sb) ? 64'(so) : 64'(sb);
            QV_AMO_MAX:  r = (so > sb) ? 64'(so) : 64'(sb);
            QV_AMO_MINU: r = (uo < ub) ? uo : ub;
            QV_AMO_MAXU: r = (uo > ub) ? uo : ub;
            default:     r = 64'hBAD;
        endcase
        return word ? {{32{r[31]}}, r[31:0]} : r;
    endfunction

    function automatic string aop_name(input qv_amo_op_e op);
        case (op)
            QV_AMO_LR:   return "LR";
            QV_AMO_SC:   return "SC";
            QV_AMO_SWAP: return "AMOSWAP";
            QV_AMO_ADD:  return "AMOADD";
            QV_AMO_XOR:  return "AMOXOR";
            QV_AMO_AND:  return "AMOAND";
            QV_AMO_OR:   return "AMOOR";
            QV_AMO_MIN:  return "AMOMIN";
            QV_AMO_MAX:  return "AMOMAX";
            QV_AMO_MINU: return "AMOMINU";
            default:     return "AMOMAXU";
        endcase
    endfunction

    // wb_mem_lock_o: up for an AMO from its first request cycle through its
    // last response cycle (the write's, or the read's if that errors),
    // continuously, and never for anything else
    logic amo_window_en = 1'b0;      // an AMO is under test
    logic lock_check_off = 1'b0;     // the flushed-AMO test checks the lock itself
    logic lock_win = 1'b0;
    int   lock_errors = 0;
    int   lock_cycles = 0;           // cycles the lock was seen during the current op
    string cur_test = "";
    task automatic lock_error(input string why);
        lock_errors++;
        if (lock_errors <= 5)
            $display("LOCK ERROR at %0t in '%s': %s (cyc=%b we=%b ack=%b err=%b lock=%b win=%b)", $time, cur_test, why, cyc, we, ack, err, lock, lock_win);
    endtask
    // sampled at the posedge, i.e. the end of every cycle, including the
    // half-cycle between the head tag arriving (at a negedge) and the edge
    always @(posedge clk) begin
        if (!rst && !lock_check_off) begin
            if (lock) lock_cycles <= lock_cycles + 1;
            if (!amo_window_en) begin
                if (lock) lock_error("lock with no AMO under test");
            end else begin
                if (!lock_win && cyc) lock_win = 1'b1;
                if (lock_win) begin
                    if (!lock) lock_error("lock dropped inside the sequence");
                    if ((ack || err) && (we || err)) lock_win = 1'b0;   // the last response: closes the window after this cycle
                end else if (lock && !cyc && !(ack || err)) begin
                    lock_error("lock after the sequence");
                end
            end
        end
    end

    // One atomic, end to end. Checks the value (rd), the exception, the bus
    // accesses and their order, memory afterwards, the lock, and the RVFI
    // fields. res_ok/res_at are the reservation commit would be holding.
    task automatic run_atomic(input string name, input qv_amo_op_e aop, input logic word,
                              input logic [63:0] a, input logic [63:0] rs2,
                              input logic res_ok, input logic [63:0] res_at, input int delay);
        logic [QV_ROB_TAG_W-1:0] t;
        logic [1:0]  size;
        logic        mis, bad, is_sc, is_lr, is_amo, sc_ok, wbad, got_wb;
        logic [63:0] old, newv, exp_v, exp_rdata, exp_wdata, wb_value;
        logic [7:0]  exp_sel;
        int          acc0, wr0, c;
        cur_test = name;
        size  = word ? 2'd2 : 2'd3;
        is_lr = (aop == QV_AMO_LR);
        is_sc = (aop == QV_AMO_SC);
        is_amo = !is_lr && !is_sc;
        mis   = misaligned(a, size);
        bad   = !mis && a[31:0] >= 32'h800;
        wbad  = !mis && !bad && (a[31:0] == werr_addr);        // only the write faults
        sc_ok = res_ok && (res_at == a);
        // an SC without its reservation never reaches the bus, so it can't fault there
        if (is_sc && !sc_ok) begin
            bad  = 1'b0;
            wbad = 1'b0;
        end
        exp_sel = golden_sel(a, size);
        old   = (!mis && !bad) ? golden_load(a, size, 1'b1) : 64'b0;
        newv  = is_amo ? golden_amo(aop, word, old, rs2) : 64'b0;
        exp_wdata = (is_sc ? rs2 : newv) << {a[2:0], 3'b000};
        acc0 = accesses; wr0 = writes;
        res_valid = res_ok; res_addr = res_at;
        amo_window_en = is_amo;
        lock_errors = lock_errors;               // (errors accumulate across the run)
        @(negedge clk); #1;
        check({name, ": slot free"}, {63'b0, free}, 64'd1);
        t = next_tag; next_tag = next_tag + 1'b1;
        req = '0; req.valid = 1'b1; req.tag = t; req.op = {1'b1, 4'(aop)}; req.is_word = word;
        req.a = a; req.b = rs2; req.imm = 64'hDEAD_DEAD;      // an atomic's address is rs1 alone
        @(posedge clk); #1;
        req = '0;
        @(negedge clk);
        head_valid = 1'b1; head_tag = t + 1'b1;
        repeat (delay) begin
            @(posedge clk); #1;
            check({name, ": no bus before head"}, {63'b0, cyc}, 64'd0);
            check({name, ": no lock before head"}, {63'b0, lock}, 64'd0);
        end
        @(negedge clk);
        head_tag = t;
        got_wb = 1'b0;
        for (c = 0; c < 90 && !got_wb; c++) begin
            #1;
            if (wb.valid) begin
                got_wb = 1'b1;
                wb_value = wb.value;
                check({name, ": wb tag"}, {60'b0, wb.tag}, {60'b0, t});
            end
            @(posedge clk);
        end
        #1;
        head_valid = 1'b0;
        check({name, ": completed"}, {63'b0, got_wb}, 64'd1);
        check({name, ": slot free at once"}, {63'b0, free}, 64'd1);
        repeat (3) @(posedge clk);                      // the lock must be down by now
        #1;
        amo_window_en = 1'b0;
        check({name, ": lock down afterwards"}, {63'b0, lock}, 64'd0);

        // ---- bus accesses ----
        if (mis)
            check({name, ": misaligned: no bus access"}, 64'(accesses - acc0), 64'd0);
        else if (is_sc && !sc_ok)
            check({name, ": SC without its reservation: no bus access"}, 64'(accesses - acc0), 64'd0);
        else if (is_amo && !bad)
            check({name, ": AMO: a read then a write"}, 64'(accesses - acc0), 64'd2);
        else
            check({name, ": one access"}, 64'(accesses - acc0), 64'd1);
        // write requests: SC with its reservation (an error comes back on the write itself),
        // an AMO whose read succeeded (even if its write then errors)
        check({name, ": write requests on the bus"}, 64'(writes - wr0),
              mis ? 64'd0 : is_sc ? (sc_ok ? 64'd1 : 64'd0) : is_amo ? (bad ? 64'd0 : 64'd1) : 64'd0);

        // ---- the exception and rd ----
        check({name, ": exception"}, {63'b0, res.xcpt},
              {63'b0, mis || bad || wbad || (is_sc && !sc_ok ? 1'b0 : 1'b0)});
        if (mis)                check({name, ": cause 6 (store/AMO class, even LR)"}, {60'b0, res.cause}, 64'd6);
        else if (bad || wbad)   check({name, ": cause 7"}, {60'b0, res.cause}, 64'd7);
        if (mis || bad || wbad) check({name, ": tval = address"}, res.tval, a);
        if (mis || bad || (wbad && is_amo)) begin
            check({name, ": rd = 0 on a fault"}, wb_value, 64'd0);
        end else if (is_lr) begin
            check({name, ": LR value"}, wb_value, old);
        end else if (is_sc) begin
            check({name, ": SC result (0 = stored, 1 = failed)"}, wb_value, sc_ok ? 64'd0 : 64'd1);
        end else if (!wbad) begin
            check({name, ": AMO rd = old value"}, wb_value, old);
        end
        if (!mis && !bad && !(is_sc && !sc_ok)) check({name, ": vaddr"}, res.vaddr, a);

        // ---- memory afterwards, and the RVFI fields ----
        if (!mis && !bad && !wbad) begin
            if (is_sc && !sc_ok) begin
                check({name, ": SC failed: no RVFI addr"}, res.mem_addr, 64'd0);
                check({name, ": SC failed: no RVFI rmask"}, {56'b0, res.mem_rmask}, 64'd0);
                check({name, ": SC failed: no RVFI wmask"}, {56'b0, res.mem_wmask}, 64'd0);
            end else begin
                check({name, ": RVFI addr"}, res.mem_addr, {a[63:3], 3'b000});
                check({name, ": RVFI rmask"}, {56'b0, res.mem_rmask}, is_sc ? 64'd0 : {56'b0, exp_sel});
                check({name, ": RVFI wmask"}, {56'b0, res.mem_wmask}, is_lr ? 64'd0 : {56'b0, exp_sel});
                if (is_amo) begin
                    check({name, ": RVFI rdata is the old value"}, res.mem_rdata, old);
                    check({name, ": RVFI wdata is the new value in its lane"}, res.mem_wdata, exp_wdata);
                end
                if (is_lr) check({name, ": RVFI rdata is the raw word"}, res.mem_rdata, gold[a[8:3]]);
                if (is_sc) check({name, ": RVFI wdata"}, res.mem_wdata, exp_wdata);
            end
            if (is_amo || (is_sc && sc_ok))
                for (int i = 0; i < 8; i++)
                    if (exp_sel[i]) gold[a[8:3]][8*i +: 8] = exp_wdata[8*i +: 8];
        end
        // a failed write leaves memory alone: the slave doesn't write on err, gold isn't updated
        if (is_amo && !mis && !bad && !wbad)
            check({name, ": lock was held during the sequence"}, {63'b0, lock_cycles > 0}, 64'd1);
        lock_cycles = 0;
    endtask

    // One data access under whatever PMP state the caller has set. kind: 0 load, 1 store, 2 LR, 3 SC, 4 AMOADD.
    // exp_deny: the PMP must deny it (judged by the caller from the regions). The bus must stay silent for a
    // denied or misaligned access; the cause is 4/6 for a misaligned one (that comes first), else 5 for a load
    // and 7 for every access that writes (LR included); tval is the address; the RVFI fields are the would-be ones.
    task automatic run_pmp(input string name, input int kind, input logic [1:0] size, input logic [63:0] a,
                           input logic exp_deny, input logic res_ok = 1'b1);
        logic [QV_ROB_TAG_W-1:0] tg;
        logic        mis, trap, store_cls, got_wb, sc_fail;
        logic [7:0]  exp_sel;
        logic [63:0] wb_value;
        int          acc0, c, n_exp;
        mis       = misaligned(a, size);
        trap      = mis || exp_deny;
        store_cls = (kind != 0);
        sc_fail   = (kind == 3) && !res_ok && !trap;
        exp_sel   = golden_sel(a, size);
        n_exp     = trap ? 0 : sc_fail ? 0 : (kind == 4) ? 2 : 1;
        acc0 = accesses;
        res_valid = res_ok; res_addr = a;
        cur_test = name;
        @(negedge clk); #1;
        tg = next_tag; next_tag = next_tag + 1'b1;
        req = '0; req.valid = 1'b1; req.tag = tg;
        case (kind)
            0: begin req.op = {1'b0, 1'b0, 1'b1, size};  req.a = a; req.b = 64'd0;  req.imm = 64'hDEAD; end
            1: begin req.op = {1'b0, 1'b1, 1'b0, size};  req.a = a; req.b = 64'h1234_5678_9ABC_DEF0; req.imm = 64'd0; end
            2: begin req.op = {1'b1, 4'(QV_AMO_LR)};     req.a = a; req.is_word = (size == 2'd2); end
            3: begin req.op = {1'b1, 4'(QV_AMO_SC)};     req.a = a; req.b = 64'hAAAA_5555_AAAA_5555; req.is_word = (size == 2'd2); end
            default: begin req.op = {1'b1, 4'(QV_AMO_ADD)}; req.a = a; req.b = 64'd1; req.is_word = (size == 2'd2); end
        endcase
        amo_window_en = (kind == 4) && !trap;
        @(posedge clk); #1;
        req = '0;
        @(negedge clk);
        head_valid = 1'b1; head_tag = tg;
        got_wb = 1'b0;
        for (c = 0; c < 90 && !got_wb; c++) begin
            #1;
            if (wb.valid) begin got_wb = 1'b1; wb_value = wb.value; end
            @(posedge clk);
        end
        #1;
        head_valid = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        amo_window_en = 1'b0;
        check({name, ": completed"}, {63'b0, got_wb}, 64'd1);
        check({name, ": bus accesses"}, 64'(accesses - acc0), 64'(n_exp));
        check({name, ": trapped"}, {63'b0, res.xcpt}, {63'b0, trap});
        if (trap) begin
            check({name, ": cause"}, {60'b0, res.cause},
                  mis ? (store_cls ? 64'd6 : 64'd4) : (store_cls ? 64'd7 : 64'd5));
            check({name, ": tval = the address"}, res.tval, a);
            check({name, ": rd = 0"}, wb_value, 64'd0);
            check({name, ": would-be RVFI addr"}, res.mem_addr, {a[63:3], 3'b000});
            check({name, ": would-be RVFI rmask"}, {56'b0, res.mem_rmask}, (kind == 0 || kind == 2 || kind == 4) ? {56'b0, exp_sel} : 64'd0);
            check({name, ": would-be RVFI wmask"}, {56'b0, res.mem_wmask}, (kind == 1 || kind == 3 || kind == 4) ? {56'b0, exp_sel} : 64'd0);
        end else if (sc_fail) begin
            check({name, ": SC without its reservation: rd = 1"}, wb_value, 64'd1);
        end
    endtask

    int s, k;
    logic [QV_ROB_TAG_W-1:0] t;
    logic [63:0] v;

    initial begin
        for (int i = 0; i < WORDS; i++) begin
            v = {$urandom, $urandom};
            mem[i] = v; gold[i] = v;
        end
        repeat (2) @(posedge clk);
        #1 rst = 1'b0;
        #1;
        check("reset: free", {63'b0, free}, 64'd1);
        check("reset: idle bus", {63'b0, cyc}, 64'd0);

        // ---- every size x offset x sign, loads then stores, then loads again ----
        for (int sz = 0; sz < 4; sz++)
            for (int o = 0; o < 8; o++) begin
                run_op($sformatf("LD sz%0d off%0d signed", sz, o), 1'b0, 2'(sz), 1'b1, 64'h100, 64'(o), 0, 0);
                run_op($sformatf("LD sz%0d off%0d unsigned", sz, o), 1'b0, 2'(sz), 1'b0, 64'h100, 64'(o), 0, 1);
                run_op($sformatf("ST sz%0d off%0d", sz, o), 1'b1, 2'(sz), 1'b0, 64'h108, 64'(o),
                       {$urandom, $urandom}, 2);
                run_op($sformatf("LD back sz%0d off%0d", sz, o), 1'b0, 2'(sz), 1'b1, 64'h108, 64'(o), 0, 0);
            end
        // negative offsets and a store-data register wider than the access
        run_op("LD negative offset", 1'b0, 2'd3, 1'b0, 64'h200, -64'd8, 0, 0);
        run_op("SB of all ones only writes one byte", 1'b1, 2'd0, 1'b0, 64'h210, 64'd3, '1, 0);
        run_op("LD sees just that byte", 1'b0, 2'd3, 1'b0, 64'h210, 64'd0, 0, 0);

        // ---- bus errors ----
        run_op("LD error", 1'b0, 2'd3, 1'b1, 64'h800, 64'd0, 0, 0);
        run_op("SW error", 1'b1, 2'd2, 1'b0, 64'h1000, 64'd4, 64'h5555, 0);
        err_with_ack = 1'b1;
        run_op("LD error+ack", 1'b0, 2'd2, 1'b1, 64'h900, 64'd4, 0, 0);
        run_op("SH error+ack", 1'b1, 2'd1, 1'b0, 64'h900, 64'd2, 64'h7777, 0);
        err_with_ack = 1'b0;

        // ---- misaligned: never on the bus ----
        run_op("LH misaligned", 1'b0, 2'd1, 1'b1, 64'h100, 64'd1, 0, 0);
        run_op("LW misaligned", 1'b0, 2'd2, 1'b0, 64'h100, 64'd6, 0, 0);
        run_op("LD misaligned", 1'b0, 2'd3, 1'b0, 64'h100, 64'd4, 0, 2);
        run_op("SH misaligned", 1'b1, 2'd1, 1'b0, 64'h100, 64'd7, 64'h1, 0);
        run_op("SD misaligned", 1'b1, 2'd3, 1'b0, 64'h100, 64'd1, 64'h1, 0);
        run_op("misaligned beyond memory still misaligned", 1'b0, 2'd2, 1'b0, 64'h800, 64'd2, 0, 0);

        // ---- flush while waiting for the head: dropped, nothing on the bus ----
        k = accesses;
        dispatch(1'b1, 2'd3, 1'b0, 64'h100, 64'd0, 64'hBAD, t);
        @(negedge clk);
        flush = 1'b1;
        @(posedge clk); #1;
        flush = 1'b0;
        check("flush waiting: slot free", {63'b0, free}, 64'd1);
        @(negedge clk);
        head_valid = 1'b1; head_tag = t;                  // the stale tag becoming "head" must do nothing
        repeat (3) begin
            @(posedge clk); #1;
            check("flush waiting: never starts", {63'b0, cyc}, 64'd0);
            check("flush waiting: never completes", {63'b0, wb.valid}, 64'd0);
        end
        head_valid = 1'b0;
        check("flush waiting: no access", 64'(accesses - k), 64'd0);

        // ---- flush in flight: request held to its response, result dropped ----
        wait_max = 0;
        dispatch(1'b0, 2'd3, 1'b0, 64'h100, 64'd0, 0, t);
        @(negedge clk);
        head_valid = 1'b1; head_tag = t;
        wait_max = 6;
        @(posedge clk); #1;                               // request out
        check("flush in flight: started", {63'b0, started}, 64'd1);
        @(negedge clk);
        head_valid = 1'b0;
        flush = 1'b1;
        @(posedge clk); #1;
        flush = 1'b0;
        for (s = 0; s < 20 && !free; s++) begin
            check("flush in flight: no completion", {63'b0, wb.valid}, 64'd0);
            @(posedge clk); #1;
        end
        check("flush in flight: slot freed after the response", {63'b0, free}, 64'd1);
        wait_max = 0;

        // ---- A extension ----
        // every AMO, both widths, every offset the width allows, and the lock around each
        for (int op = QV_AMO_SWAP; op <= QV_AMO_MAXU; op++)
            for (int w = 0; w < 2; w++)
                for (int o = 0; o < 16; o += (w ? 4 : 8))
                    run_atomic($sformatf("%s.%s @%0d", aop_name(qv_amo_op_e'(op)), w ? "W" : "D", o),
                               qv_amo_op_e'(op), w[0], 64'h100 + 64'(o),
                               ($urandom % 2) ? {$urandom, $urandom} : (o[2] ? 64'hFFFF_FFFF_8000_0000 : 64'h8000_0000_0000_0000),
                               1'b0, 64'b0, $urandom % 3);
        // operand edges for the compares and the sign extension
        begin
            logic [63:0] edge_v [0:5] = '{64'd0, 64'd1, 64'hFFFF_FFFF_FFFF_FFFF, 64'h8000_0000_0000_0000,
                                          64'h7FFF_FFFF_FFFF_FFFF, 64'h0000_0000_8000_0000};
            for (int op = QV_AMO_SWAP; op <= QV_AMO_MAXU; op++)
                for (int w = 0; w < 2; w++)
                    for (int i = 0; i < 6; i++)
                        for (int j = 0; j < 6; j++) begin
                            // seed memory with edge_v[i], then apply the op with edge_v[j]
                            gold[32] = edge_v[i]; mem[32] = edge_v[i];
                            run_atomic($sformatf("%s.%s edge %0d,%0d", aop_name(qv_amo_op_e'(op)), w ? "W" : "D", i, j),
                                       qv_amo_op_e'(op), w[0], 64'h100, edge_v[j], 1'b0, 64'b0, 0);
                        end
        end
        // LR / SC
        for (int w = 0; w < 2; w++) begin
            run_atomic("LR", QV_AMO_LR, w[0], 64'h140, 64'b0, 1'b0, 64'b0, 1);
            run_atomic("LR negative", QV_AMO_LR, w[0], 64'h148, 64'b0, 1'b0, 64'b0, 0);
            // reservation matches: stores, rd = 0
            run_atomic("SC with its reservation", QV_AMO_SC, w[0], 64'h150, {$urandom, $urandom}, 1'b1, 64'h150, 0);
            // no reservation / a different address / invalid: nothing happens, rd = 1
            run_atomic("SC, no reservation", QV_AMO_SC, w[0], 64'h158, 64'h1234, 1'b0, 64'h158, 0);
            run_atomic("SC, reservation for another address", QV_AMO_SC, w[0], 64'h160, 64'h1234, 1'b1, 64'h168, 1);
            run_atomic("SC, reservation for the same dword, other word", QV_AMO_SC, w[0], 64'h164 - (w ? 0 : 4),
                       64'h5678, 1'b1, 64'h160, 0);
        end
        // the compare is the full 64-bit address: bits above the bus width count
        run_atomic("SC, reservation differs only in bit 40", QV_AMO_SC, 1'b0, 64'h170, 64'h99, 1'b1, 64'h170 | (64'd1 << 40), 0);
        // width doesn't enter the reservation compare: LR.W then SC.D at the same address hold
        run_atomic("SC.D with a reservation taken by LR.W's address", QV_AMO_SC, 1'b0, 64'h178, 64'hABCD, 1'b1, 64'h178, 0);

        // misaligned: cause 6 for all of them, never on the bus
        for (int w = 0; w < 2; w++)
            for (int m = 1; m < (w ? 4 : 8); m++) begin
                run_atomic($sformatf("LR misaligned +%0d", m), QV_AMO_LR, w[0], 64'h100 + 64'(m), 64'b0, 1'b0, 64'b0, 0);
                run_atomic($sformatf("AMOADD misaligned +%0d", m), QV_AMO_ADD, w[0], 64'h100 + 64'(m), 64'h1, 1'b0, 64'b0, 0);
                run_atomic($sformatf("SC misaligned +%0d (with its reservation)", m), QV_AMO_SC, w[0], 64'h100 + 64'(m), 64'h1,
                           1'b1, 64'h100 + 64'(m), 0);
                run_atomic($sformatf("SC misaligned +%0d (without)", m), QV_AMO_SC, w[0], 64'h100 + 64'(m), 64'h1, 1'b0, 64'b0, 0);
            end

        // bus errors: LR, SC and the AMO's read are all cause 7
        err_with_ack = 1'b0;
        for (int e = 0; e < 2; e++) begin
            run_atomic("LR bus error", QV_AMO_LR, e[0], 64'h800, 64'b0, 1'b0, 64'b0, 0);
            run_atomic("AMOSWAP bus error (read)", QV_AMO_SWAP, e[0], 64'h808, 64'h55, 1'b0, 64'b0, 0);
            run_atomic("SC bus error", QV_AMO_SC, e[0], 64'h810, 64'h55, 1'b1, 64'h810, 0);
            err_with_ack = 1'b1;
        end
        err_with_ack = 1'b0;
        // the write errors, the read doesn't: still one fault, rd untouched, memory unchanged
        for (int w = 0; w < 2; w++) begin
            werr_addr = 32'h180;
            run_atomic("AMOADD write-phase error", QV_AMO_ADD, w[0], 64'h180, 64'h1, 1'b0, 64'b0, 0);
            run_atomic("AMOMAXU write-phase error", QV_AMO_MAXU, w[0], 64'h180, 64'hFFFF_FFFF_FFFF_FFFF, 1'b0, 64'b0, 0);
            run_atomic("SC write error", QV_AMO_SC, w[0], 64'h180, 64'h7, 1'b1, 64'h180, 0);
            werr_addr = 32'hFFFF_FFFF;
        end

        // plain ops don't touch the lock: a locked run of plain loads/stores
        for (int i = 0; i < 6; i++)
            run_op($sformatf("plain op %0d between atomics", i), i[0], 2'(2 + (i % 2)), 1'b1, 64'h100, 64'(i * 8), {$urandom, $urandom}, 0);

        // flush while waiting for the head: dropped
        k = accesses;
        res_valid = 1'b0;
        amo_window_en = 1'b1;
        lock_check_off = 1'b1;
        @(negedge clk); #1;
        t = next_tag; next_tag = next_tag + 1'b1;
        req = '0; req.valid = 1'b1; req.tag = t; req.op = {1'b1, 4'(QV_AMO_ADD)}; req.is_word = 1'b0;
        req.a = 64'h100; req.b = 64'h5;
        @(posedge clk); #1;
        req = '0;
        @(negedge clk); flush = 1'b1;
        @(posedge clk); #1; flush = 1'b0;
        check("AMO flushed while waiting: slot free", {63'b0, free}, 64'd1);
        @(negedge clk); head_valid = 1'b1; head_tag = t;
        repeat (3) begin @(posedge clk); #1; check("AMO flushed while waiting: nothing starts", {63'b0, cyc | lock | wb.valid}, 64'd0); end
        head_valid = 1'b0;
        check("AMO flushed while waiting: no access", 64'(accesses - k), 64'd0);

        // flush at each cycle around an AMO's read response: a flush in the start
        // cycle stops it before any request; later ones let the read finish
        // (never abandoned) but no write may follow, even when the flush
        // arrives in the very cycle of the read's response
        lock_check_off = 1'b1;
        for (int wm = 0; wm < 3; wm++)
            for (int fo = 0; fo < 3; fo++) begin
                if (fo == 2 && wm != 0) continue;           // only with no wait states is cycle 2 the response cycle
                wait_max = (wm == 0) ? 0 : (wm == 1) ? 2 : 5;
                k = accesses;
                @(negedge clk); #1;
                t = next_tag; next_tag = next_tag + 1'b1;
                req = '0; req.valid = 1'b1; req.tag = t; req.op = {1'b1, 4'(QV_AMO_ADD)}; req.is_word = 1'b0;
                req.a = 64'h100; req.b = 64'h5;
                @(posedge clk); #1;
                req = '0;
                @(negedge clk);
                head_valid = 1'b1; head_tag = t;               // the start cycle begins
                repeat (fo) begin @(posedge clk); #1; @(negedge clk); end
                flush = 1'b1;                                  // fo cycles after the start (0: the start cycle itself)
                @(posedge clk); #1;
                flush = 1'b0; head_valid = 1'b0;
                for (s = 0; s < 40 && !free; s++) begin
                    check($sformatf("AMO flushed at +%0d (waits %0d): no completion afterwards", fo, wm), {63'b0, wb.valid}, 64'd0);
                    @(posedge clk); #1;
                end
                check($sformatf("AMO flushed at +%0d (waits %0d): slot free", fo, wm), {63'b0, free}, 64'd1);
                repeat (8) @(posedge clk);
                #1;
                check($sformatf("AMO flushed at +%0d (waits %0d): requests issued", fo, wm), 64'(accesses - k), (fo == 0) ? 64'd0 : 64'd1);
                check($sformatf("AMO flushed at +%0d (waits %0d): lock down", fo, wm), {63'b0, lock}, 64'd0);
            end
        wait_max = 0;

        // flush while the AMO's read is in flight: the read finishes (never abandoned), no write follows
        wait_max = 0;
        k = accesses;
        @(negedge clk); #1;
        t = next_tag; next_tag = next_tag + 1'b1;
        req = '0; req.valid = 1'b1; req.tag = t; req.op = {1'b1, 4'(QV_AMO_ADD)}; req.is_word = 1'b0;
        req.a = 64'h100; req.b = 64'h5;
        @(posedge clk); #1;
        req = '0;
        @(negedge clk);
        head_valid = 1'b1; head_tag = t;
        wait_max = 6;
        @(posedge clk); #1;
        check("AMO read in flight: started with the lock", {63'b0, started & lock}, 64'd1);
        @(negedge clk);
        head_valid = 1'b0;
        flush = 1'b1;
        @(posedge clk); #1;
        flush = 1'b0;
        for (s = 0; s < 40 && !free; s++) begin
            check("AMO read in flight, flushed: no completion", {63'b0, wb.valid}, 64'd0);
            @(posedge clk); #1;
        end
        check("AMO read in flight, flushed: slot freed after the read's response", {63'b0, free}, 64'd1);
        repeat (6) @(posedge clk);
        #1;
        check("AMO read in flight, flushed: only the read was issued", 64'(accesses - k), 64'd1);
        check("AMO read in flight, flushed: lock down", {63'b0, lock}, 64'd0);
        amo_window_en = 1'b0;
        lock_check_off = 1'b0;
        lock_win = 1'b0;
        wait_max = 0;
        check("lock never outside an AMO's own sequence", 64'(lock_errors), 64'd0);

        // ---- random: mixed ops, random wait states and head delays ----
        for (s = 0; s < 3000; s++) begin
            logic st;
            logic [1:0] sz;
            logic [63:0] base, off;
            wait_max = $urandom % 4;
            st   = $urandom % 2;
            sz   = $urandom % 4;
            base = 64'h100 + 64'($urandom % 64) * 8;
            off  = ($urandom % 10 == 0) ? 64'(int'($urandom % 2048) - 1024) : 64'($urandom % 16);
            if ($urandom % 20 == 0) base = 64'h900;       // into the error range
            run_op($sformatf("random %0d", s), st, sz, 1'($urandom), base, off, {$urandom, $urandom},
                   $urandom % 3);
        end

        // ---- random atomics, interleaved with plain ops ----
        for (s = 0; s < 1500; s++) begin
            logic [63:0] ar;
            logic wd;
            wait_max = $urandom % 4;
            wd = $urandom % 2;
            ar = 64'h100 + 64'($urandom % 64) * 8 + (wd ? 64'($urandom % 2) * 4 : 64'd0);
            if ($urandom % 12 == 0) ar += 64'($urandom % 8);                  // misaligned for most
            if ($urandom % 25 == 0) ar = 64'h800 + 64'($urandom % 4) * 8;     // bus error
            if ($urandom % 3 == 0) begin
                run_op($sformatf("random plain %0d", s), $urandom % 2, 2'($urandom % 4), 1'($urandom),
                       64'h100 + 64'($urandom % 64) * 8, 64'($urandom % 8), {$urandom, $urandom}, $urandom % 3);
            end else begin
                run_atomic($sformatf("random atomic %0d", s), qv_amo_op_e'($urandom % 11), wd, ar, {$urandom, $urandom},
                           $urandom % 2, ($urandom % 3 == 0) ? 64'h100 + 64'($urandom % 64) * 8 : ar, $urandom % 3);
            end
        end
        check("lock errors over the whole run", 64'(lock_errors), 64'd0);

        check("bus protocol held throughout", {63'b0, proto_ok}, 64'd1);
        for (int i = 0; i < WORDS; i++) check($sformatf("final memory dword %0d", i), mem[i], gold[i]);

        // ---------------- PMP ----------------
        wait_max = 1;
        // region 0: TOR [0, 0x100) read-only; 1: TOR [0x100, 0x200) read+write; 2: NAPOT [0x200, 0x240) write-only
        pmpcfg0  = {32'b0, 8'h00, 8'h1A, 8'h0B, 8'h09};
        pmpaddr0 = 64'h100 >> 2; pmpaddr1 = 64'h200 >> 2; pmpaddr2 = (64'h200 >> 2) | 64'h7;
        priv = 2'b01; mprv = 1'b0; mpp = 2'b11;
        for (int sz = 0; sz < 4; sz++) begin
            logic [63:0] a_ro, a_rw, a_wo;
            a_ro = 64'h40 + 64'(sz) * 8; a_rw = 64'h140 + 64'(sz) * 8; a_wo = 64'h210 + 64'(sz) * 8;
            run_pmp($sformatf("S load sz%0d in R region", sz),  0, 2'(sz), a_ro, 1'b0);
            run_pmp($sformatf("S store sz%0d in R region", sz), 1, 2'(sz), a_ro, 1'b1);
            run_pmp($sformatf("S load sz%0d in RW region", sz),  0, 2'(sz), a_rw, 1'b0);
            run_pmp($sformatf("S store sz%0d in RW region", sz), 1, 2'(sz), a_rw, 1'b0);
            run_pmp($sformatf("S load sz%0d in W region", sz),  0, 2'(sz), a_wo, 1'b1);
            run_pmp($sformatf("S store sz%0d in W region", sz), 1, 2'(sz), a_wo, 1'b0);
        end
        // LR, SC and the AMOs write as far as the PMP is concerned (ref_core.sv), so the R-only region denies them
        run_pmp("S LR.D in R region",  2, 2'd3, 64'h40, 1'b1);
        run_pmp("S LR.W in RW region", 2, 2'd2, 64'h144, 1'b0);
        run_pmp("S LR.D in W region",  2, 2'd3, 64'h210, 1'b0);
        run_pmp("S AMOADD.D in R region", 4, 2'd3, 64'h48, 1'b1);
        run_pmp("S AMOADD.W in RW region", 4, 2'd2, 64'h148, 1'b0);
        run_pmp("S SC.D in R region, with its reservation", 3, 2'd3, 64'h40, 1'b1, 1'b1);
        run_pmp("S SC.D in R region, without one: the PMP is judged first", 3, 2'd3, 64'h40, 1'b1, 1'b0);
        run_pmp("S SC.D in RW region, with its reservation", 3, 2'd3, 64'h150, 1'b0, 1'b1);
        run_pmp("S SC.D in RW region, without one: rd = 1, no access", 3, 2'd3, 64'h150, 1'b0, 1'b0);
        // an odd address inside the region still reports itself as tval
        run_pmp("S LH at an odd halfword in R region", 0, 2'd1, 64'h42, 1'b0);
        run_pmp("S SH at an odd halfword in R region", 1, 2'd1, 64'h42, 1'b1);
        // misaligned comes first, whatever the PMP says
        run_pmp("S SW misaligned in R region: 6, not 7", 1, 2'd2, 64'h42, 1'b1);
        run_pmp("S LD misaligned in W region: 4, not 5", 0, 2'd3, 64'h214, 1'b1);
        run_pmp("S AMOADD.D misaligned in R region: 6", 4, 2'd3, 64'h44, 1'b1);
        // outside every region: nothing below M gets in
        run_pmp("S load, no region", 0, 2'd3, 64'h300, 1'b1);
        run_pmp("S store, no region", 1, 2'd3, 64'h300, 1'b1);
        // a span that leaves its region is no match at all: pmpaddr0 on a 4-byte boundary that is not a dword's
        pmpaddr0 = 64'h104 >> 2; pmpaddr1 = 64'h200 >> 2;
        run_pmp("S LD at 0xF8, span inside region 0", 0, 2'd3, 64'hF8, 1'b0);
        run_pmp("S LW at 0x100, inside region 0", 0, 2'd2, 64'h100, 1'b0);
        run_pmp("S LD at 0x100, span [0x100,0x107] leaves region 0", 0, 2'd3, 64'h100, 1'b1);
        pmpaddr0 = 64'h100 >> 2;
        // other privileges
        priv = 2'b00;
        run_pmp("U store in R region", 1, 2'd3, 64'h40, 1'b1);
        run_pmp("U load in R region", 0, 2'd3, 64'h40, 1'b0);
        priv = 2'b10;
        run_pmp("privilege 2 store in R region", 1, 2'd3, 64'h40, 1'b1);
        priv = 2'b11;
        run_pmp("M store in R region: unlocked, no denial", 1, 2'd3, 64'h40, 1'b0);
        run_pmp("M load, no region: no denial", 0, 2'd3, 64'h300, 1'b0);
        pmpcfg0[7] = 1'b1;                                                    // lock region 0
        run_pmp("M store in a locked R region: denied", 1, 2'd3, 64'h40, 1'b1);
        run_pmp("M load in a locked R region", 0, 2'd3, 64'h40, 1'b0);
        run_pmp("M store, region 1 unlocked", 1, 2'd3, 64'h140, 1'b0);
        pmpcfg0[7] = 1'b0;
        // MPRV: M-mode data accesses run at MPP
        mprv = 1'b1; mpp = 2'b01;
        run_pmp("M with MPRV, MPP = S: store in R region denied", 1, 2'd3, 64'h40, 1'b1);
        run_pmp("M with MPRV, MPP = S: load in R region", 0, 2'd3, 64'h40, 1'b0);
        run_pmp("M with MPRV, MPP = S: no region", 0, 2'd3, 64'h300, 1'b1);
        mpp = 2'b11;
        run_pmp("M with MPRV, MPP = M: store in R region fine", 1, 2'd3, 64'h40, 1'b0);
        mpp = 2'b01; priv = 2'b01;
        run_pmp("S with MPRV set: MPRV is for M only (S store in RW region)", 1, 2'd3, 64'h140, 1'b0);
        run_pmp("S with MPRV set: still checked as S (R region)", 1, 2'd3, 64'h40, 1'b1);
        mpp = 2'b11; priv = 2'b01;
        run_pmp("S with MPRV set and MPP = M: still checked as S (R region)", 1, 2'd3, 64'h40, 1'b1);
        mprv = 1'b0; priv = 2'b11; mpp = 2'b11;
        // the span starts at the access itself, not at its dword: a region that begins at a word inside a dword
        priv = 2'b01;
        pmpcfg0 = {32'b0, 8'h00, 8'h00, 8'h0B, 8'h08};                        // 0: TOR [0, 0x104) no permissions; 1: TOR [0x104, 0x200) RW
        pmpaddr0 = 64'h104 >> 2; pmpaddr1 = 64'h200 >> 2;
        run_pmp("S LW at 0x104: the region starts mid-dword", 0, 2'd2, 64'h104, 1'b0);
        run_pmp("S SW at 0x104", 1, 2'd2, 64'h104, 1'b0);
        run_pmp("S LW at 0x100: below the region", 0, 2'd2, 64'h100, 1'b1);
        pmpcfg0 = {32'b0, 8'h00, 8'h1A, 8'h0B, 8'h09}; pmpaddr0 = 64'h100 >> 2; pmpaddr1 = 64'h200 >> 2;
        // a denied access leaves the unit free and in order: a normal op right after works
        priv = 2'b01;
        run_pmp("S store denied ...", 1, 2'd3, 64'h40, 1'b1);
        run_pmp("... and the next load is fine", 0, 2'd3, 64'h48, 1'b0);
        // a Program Buffer run is trusted: the very accesses denied above go through, each kind, and a misaligned
        // one still traps first
        priv = 2'b01; pmp_bypass = 1'b1;
        run_pmp("bypass: S store in R region", 1, 2'd3, 64'h40, 1'b0);
        run_pmp("bypass: S load, no region", 0, 2'd3, 64'h300, 1'b0);
        run_pmp("bypass: S LR.D in R region", 2, 2'd3, 64'h40, 1'b0);
        run_pmp("bypass: S AMOADD.D in R region", 4, 2'd3, 64'h48, 1'b0);
        run_pmp("bypass: S SC.D in R region, with its reservation", 3, 2'd3, 64'h40, 1'b0, 1'b1);
        run_pmp("bypass: S SC.D in R region, without one: rd = 1, no access", 3, 2'd3, 64'h40, 1'b0, 1'b0);
        run_pmp("bypass: SW misaligned: 6", 1, 2'd2, 64'h42, 1'b0);
        pmp_bypass = 1'b0;
        run_pmp("bypass off: the same store is denied again", 1, 2'd3, 64'h40, 1'b1);
        // back to the reset state
        priv = 2'b11; mpp = 2'b11; mprv = 1'b0;
        pmpcfg0 = 64'h1F; pmpaddr0 = 64'h003F_FFFF_FFFF_FFFF; pmpaddr1 = '0; pmpaddr2 = '0;
        check("PMP section: bus protocol held", {63'b0, proto_ok}, 64'd1);
        check("PMP section: no lock errors", 64'(lock_errors), 64'd0);

        $display("");
        $display("qv_lsu_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_lsu_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT: qv_lsu_tb");
        $finish;
    end
endmodule
