// SPDX-License-Identifier: MIT

/*
 * qv_lsu_xl_tb -- the LSU's translation, end to end: qv_lsu with a qv_xlate (its
 * TLB) and the page-table walker qv_ptw, sharing one memory port the way
 * the core does, over the page-table environment of testbench/qv_pt_env.svh.
 * (qv_lsu_tb covers the LSU without translation.)
 *
 * Directed, each op judged against a model of what it must do:
 *   - an access with translation off (Bare, M mode, a Program Buffer run) is
 *     what qv_lsu_tb checks: no walk, the address is the physical one
 *   - a translated load or store: PTE reads first, three of them, then the
 *     access at the physical address; nothing at all reaches the bus before
 *     the op is the ROB head, PTE reads included
 *   - a TLB hit: no PTE read
 *   - misaligned: cause 4/6 and no walk; a failing SC under translation: rd = 1,
 *     no walk and no PMP check (the physical address would have been denied)
 *   - page faults: 13 for a load or LR, 15 for a store, SC or AMO, tval the
 *     virtual address; access faults from the walk (PMP-denied table page, bus
 *     error on a PTE): 5 for a load, 7 for everything that writes (LR too)
 *   - the PMP is judged on the physical address at the effective privilege, not
 *     on the virtual one; MPRV runs M mode at MPP
 *   - an AMO is translated once and its read and write use the same address
 *   - a flush while a walk is pending drops the op and leaves the walker free
 * Then a random sweep of everything with random page tables, contexts, errors
 * and a second client (fetch-side walks) competing for the walker, every op
 * compared with the model: its outcome, rd, memory afterwards, the number of
 * PTE reads and of data accesses.
 */
module qv_lsu_xl_tb;
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // ---------------- the ROB side ----------------
    logic                    flush = 1'b0;
    fu_req_t                 req = '0;
    wire                     free;
    logic                    head_valid = 1'b0;
    logic [QV_ROB_TAG_W-1:0] head_tag = '0;
    logic                    res_valid = 1'b0;
    logic [63:0]             res_addr = '0;

    // the context
    logic [1:0]  priv = 2'b01, mpp = 2'b11;
    logic        mprv = 1'b0, pmp_bypass = 1'b0, sum = 1'b0, mxr = 1'b0, satp_on = 1'b1, sfence = 1'b0;
    logic [43:0] satp_root = 44'd2;
    logic [63:0] pmpcfg0 = '0, pmpaddr0 = '0, pmpaddr1 = '0, pmpaddr2 = '0, pmpaddr3 = '0;

    // ---------------- the LSU, its translator, the walker, the shared port ----------------
    wire  [31:0] lsu_addr;
    wire  [63:0] lsu_dat;
    wire  [7:0]  lsu_sel;
    wire         lsu_we, lsu_cyc, lsu_stb, lsu_lock;
    wb_t         wb;
    lsu_res_t    res;
    wire         started, lsu_busy_w;
    wire         x_req, x_wr, x_active, x_cancel, x_done, x_pf, x_af;
    wire  [63:0] x_va;
    wire  [1:0]  x_priv;
    wire  [43:0] x_ppn;
    wire         ptw_beat, ptw_cyc;
    wire  [31:0] ptw_addr;

    logic [63:0] bus_dat = '0;
    logic        bus_ack = 1'b0, bus_err = 1'b0;
    wire  [31:0] bus_addr = ptw_beat ? ptw_addr : lsu_addr;
    wire         bus_cyc  = ptw_beat ? ptw_cyc : lsu_cyc;
    wire         bus_we   = ptw_beat ? 1'b0 : lsu_we;
    wire  [7:0]  bus_sel  = ptw_beat ? 8'hFF : lsu_sel;
    wire  [63:0] bus_dato = lsu_dat;
    wire         beat     = ptw_beat;
    wire         lsu_busy = lsu_busy_w;

    qv_lsu dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(req), .o_free(free),
        .i_head_valid(head_valid), .i_head_tag(head_tag),
        .i_res_valid(res_valid), .i_res_addr(res_addr),
        .i_priv(priv), .i_mprv(mprv), .i_mpp(mpp), .i_pmp_bypass(pmp_bypass),
        .i_pmpcfg0(pmpcfg0), .i_pmpaddr0(pmpaddr0), .i_pmpaddr1(pmpaddr1), .i_pmpaddr2(pmpaddr2), .i_pmpaddr3(pmpaddr3),
        .wb_mem_addr_o(lsu_addr), .wb_mem_dat_o(lsu_dat), .wb_mem_sel_o(lsu_sel), .wb_mem_we_o(lsu_we),
        .wb_mem_cyc_o(lsu_cyc), .wb_mem_stb_o(lsu_stb), .wb_mem_lock_o(lsu_lock),
        .wb_mem_dat_i(bus_dat), .wb_mem_ack_i(bus_ack), .wb_mem_err_i(bus_err),
        .o_wb(wb), .o_res(res), .o_head_started(started),
        .i_satp_on(satp_on),
        .o_xl_req(x_req), .o_xl_va(x_va), .o_xl_wr(x_wr), .o_xl_active(x_active), .o_xl_priv(x_priv), .o_xl_cancel(x_cancel),
        .i_xl_done(x_done), .i_xl_pf(x_pf), .i_xl_af(x_af), .i_xl_ppn(x_ppn),
        .i_ptw_beat(ptw_beat), .o_bus_busy(lsu_busy_w)
    );

    // the fetch-side client of the walker, driven by the testbench (it only competes)
    logic        f_req = 1'b0, f_cancel = 1'b0;
    logic [63:0] f_va = '0;
    logic [1:0]  f_priv = 2'b01;
    wire         w_d_req, w_d_cancel, w_d_done, w_f_done;
    wire         w_ok, w_pf, w_af, w_r, w_w, w_x, w_u, w_d;
    wire  [26:0] w_vpn;
    wire  [1:0]  w_level;
    wire  [43:0] w_ppn;

    qv_ptw ptw0 (
        .clk(clk), .rst(rst),
        .o_bus_addr(ptw_addr), .o_bus_cyc(ptw_cyc), .i_bus_dat(bus_dat), .i_bus_ack(bus_ack), .i_bus_err(bus_err),
        .i_lsu_busy(lsu_busy_w), .o_beat(ptw_beat),
        .i_pmpcfg0(pmpcfg0), .i_pmpaddr0(pmpaddr0), .i_pmpaddr1(pmpaddr1), .i_pmpaddr2(pmpaddr2), .i_pmpaddr3(pmpaddr3),
        .i_d_req(w_d_req), .i_d_va(x_va), .i_d_wr(x_wr), .i_d_priv(x_priv), .i_d_sum(sum), .i_d_mxr(mxr),
        .i_d_root(satp_root), .i_d_cancel(w_d_cancel), .o_d_done(w_d_done),
        .i_f_req(f_req), .i_f_va(f_va), .i_f_priv(f_priv), .i_f_root(satp_root), .i_f_cancel(f_cancel), .o_f_done(w_f_done),
        .o_res_ok(w_ok), .o_res_pf(w_pf), .o_res_af(w_af), .o_res_vpn(w_vpn), .o_res_level(w_level), .o_res_ppn(w_ppn),
        .o_res_r(w_r), .o_res_w(w_w), .o_res_x(w_x), .o_res_u(w_u), .o_res_d(w_d)
    );

    qv_xlate #(.TLB_ENTRIES(4)) xd (
        .clk(clk), .rst(rst),
        .i_req(x_req), .i_va(x_va), .i_is_mem(1'b1), .i_wr(x_wr), .i_active(x_active), .i_priv(x_priv),
        .i_sum(sum), .i_mxr(mxr), .i_cancel(x_cancel), .i_flush_tlb(sfence),
        .o_done(x_done), .o_pf(x_pf), .o_af(x_af), .o_ppn(x_ppn),
        .o_w_req(w_d_req), .o_w_cancel(w_d_cancel),
        .i_w_done(w_d_done), .i_w_ok(w_ok), .i_w_pf(w_pf), .i_w_af(w_af), .i_w_vpn(w_vpn), .i_w_level(w_level),
        .i_w_ppn(w_ppn), .i_w_r(w_r), .i_w_w(w_w), .i_w_x(w_x), .i_w_u(w_u), .i_w_d(w_d)
    );

    `include "qv_pt_env.svh"

    // ---------------- who is on the port ----------------
    // PTE reads go to the table pages (below 0x10000), data accesses to the data pages from 0x10000 up
    localparam int DATA_BASE = 32'h10000;
    int  pte_reads = 0, pte_reads_f = 0, data_accs = 0, data_writes = 0, port_overlaps = 0;
    logic prev_bus_cyc = 1'b0;
    // the bus cycle that belongs to the LSU's op: its own access, or a walk beat done for it (client D of the walker)
    wire d_bus_cyc = bus_cyc && !(ptw_beat && ptw0.cl_q);
    always @(posedge clk) begin
        if (!rst) begin
            if (bus_cyc && !prev_bus_cyc) begin
                if (bus_addr < DATA_BASE) begin if (ptw0.cl_q) pte_reads_f++; else pte_reads++; end
                else begin data_accs++; if (bus_we) data_writes++; end
            end
            // the two masters never drive the port in the same cycle
            if (lsu_cyc && ptw_cyc) port_overlaps++;
        end
        prev_bus_cyc <= bus_cyc;
    end

    // ---------------- the data pages and the golden memory ----------------
    // data page i: PPN 0x10 + i (PA 0x10000 + 4096 i), i = 0..7
    logic [63:0] gold [0:4095];
    // (the bus carries PA[31:0] only: a page number above 4 GB aliases onto the data pages)
    function automatic int gidx(input logic [63:0] pa);
        return int'(({32'b0, pa[31:0]} - 64'h10000) >> 3);
    endfunction
    task automatic reset_data;
        logic [63:0] v;
        begin
            for (int i = 0; i < 4096; i++) begin
                v = {$urandom, $urandom};
                mem[16 * 512 + i] = v;
                gold[i] = v;
            end
        end
    endtask

    function automatic logic [63:0] golden_load(input logic [63:0] pa, input logic [1:0] size, input logic sgn);
        logic [63:0] w, s;
        w = gold[gidx({pa[63:3], 3'b000})];
        s = w >> {pa[2:0], 3'b000};
        case (size)
            2'd0:    return sgn ? {{56{s[7]}}, s[7:0]}   : {56'b0, s[7:0]};
            2'd1:    return sgn ? {{48{s[15]}}, s[15:0]} : {48'b0, s[15:0]};
            2'd2:    return sgn ? {{32{s[31]}}, s[31:0]} : {32'b0, s[31:0]};
            default: return s;
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
    task automatic gold_write(input logic [63:0] pa, input logic [7:0] sel, input logic [63:0] dat);
        begin
            for (int i = 0; i < 8; i++)
                if (sel[i]) gold[gidx({pa[63:3], 3'b000})][8*i +: 8] = dat[8*i +: 8];
        end
    endtask

    // ---------------- building the map ----------------
    // vpn2 = 1 -> L1T, vpn1 = 2 -> L0T, vpn0 = i -> data page i with the given flags (0..7)
    task automatic data_map(input logic [7:0] flags);
        begin
            for (int i = 0; i < 512; i++) begin put(ROOT, i, 64'd0); put(L1T, i, 64'd0); put(L0T, i, 64'd0); end
            put(ROOT, 1, pte_of(L1T, V));
            put(L1T, 2, pte_of(L0T, V));
            for (int i = 0; i < 8; i++) put(L0T, i, pte_of(44'h10 + i, flags));
        end
    endtask
    function automatic logic [63:0] vpg(input int pg, input logic [11:0] off);
        return va_of(9'd1, 9'd2, 9'(pg), off);
    endfunction

    logic [QV_ROB_TAG_W-1:0] next_tag = '0;

    // ---------------- one op, end to end ----------------
    // kind: 0 load, 1 store, 2 LR, 3 SC, 4 AMOADD
    int          t_pte, t_data;                    // the reads and accesses the last op made
    logic        t_xcpt;
    logic [3:0]  t_cause;
    logic [63:0] t_tval, t_rd, t_vaddr, t_mem_addr;
    bit          t_done;

    task automatic run_xl(input string name, input int kind, input logic [1:0] size, input logic sgn, input logic [63:0] va,
                          input logic [63:0] data, input logic sc_res_ok, input int delay, input bit check_pte_reads,
                          input bit flush_tlb_first);
        logic [QV_ROB_TAG_W-1:0] tg;
        logic        mis, fault_st, kind_wr, sc_fail, xl_on, got_wb;
        logic [1:0]  eff;
        logic [63:0] pa, exp_rd, wb_value, exp_pa;
        logic [7:0]  sel;
        int          exp_pte, exp_data, exp_writes, c;
        bit          exp_xcpt, exp_deny;
        logic [3:0]  exp_cause;
        logic [63:0] old, newv;
        begin
            fault_st = (kind != 0);
            kind_wr  = (kind == 1) || (kind == 3) || (kind == 4);
            mis      = misaligned(va, size);
            eff      = (mprv && priv == 2'b11) ? mpp : priv;
            xl_on    = satp_on && !pmp_bypass && (eff != 2'b11);
            sc_fail  = (kind == 3) && !(sc_res_ok);                 // the reservation matches va whenever it is held
            sel      = golden_sel(va, size);
            exp_xcpt = 1'b0; exp_cause = 4'd0; exp_pte = 0; exp_data = 0; exp_writes = 0; exp_rd = 64'b0; exp_pa = va;
            if (flush_tlb_first) begin sfence = 1'b1; @(posedge clk); #1; sfence = 1'b0; end

            // ---- the model ----
            if (mis) begin
                exp_xcpt = 1'b1; exp_cause = fault_st ? 4'd6 : 4'd4;
            end else if (kind == 3 && sc_fail && xl_on) begin
                exp_rd = 64'd1;                                   // no walk, no PMP
            end else begin
                if (xl_on) begin
                    model_walk(va, 1'b1, kind_wr, eff, sum, mxr, satp_root);
                    exp_pte = m_beats;
                    if (m_kind == 1) begin
                        exp_xcpt = 1'b1; exp_cause = kind_wr ? 4'd15 : 4'd13;
                    end else if (m_kind == 2) begin
                        exp_xcpt = 1'b1; exp_cause = fault_st ? 4'd7 : 4'd5;
                    end else begin
                        exp_pa = {resolved(m_ppn, m_level, va), va[11:0]};
                    end
                end
                if (!exp_xcpt) begin
                    pa = exp_pa;
                    exp_deny = !pmp_bypass && (eff != 2'b11) && model_deny(pa);   // an unlocked region never denies M mode
                    if (exp_deny) begin
                        exp_xcpt = 1'b1; exp_cause = fault_st ? 4'd7 : 4'd5;
                    end else if (kind == 3 && sc_fail) begin
                        exp_rd = 64'd1;
                    end else begin
                        exp_data = (kind == 4) ? 2 : 1;
                        exp_writes = (kind == 1 || kind == 3) ? 1 : (kind == 4) ? 1 : 0;
                        if (kind == 0 || kind == 2) exp_rd = golden_load(exp_pa, size, (kind == 2) ? 1'b1 : sgn);
                        if (kind == 3) exp_rd = 64'd0;
                        if (kind == 4) begin
                            old = golden_load(exp_pa, size, 1'b1);
                            exp_rd = old;
                        end
                    end
                end
            end

            // ---- the stimulus ----
            res_valid = sc_res_ok; res_addr = va;
            pte_reads = 0; data_accs = 0; data_writes = 0;
            @(negedge clk); #1;
            tg = next_tag; next_tag = next_tag + 1'b1;
            req = '0; req.valid = 1'b1; req.tag = tg;
            case (kind)
                0: begin req.op = {1'b0, 1'b0, sgn, size}; req.a = va; req.b = 64'd0; req.imm = 64'hDEAD; end
                1: begin req.op = {1'b0, 1'b1, 1'b0, size}; req.a = va; req.b = data; req.imm = 64'd0; end
                2: begin req.op = {1'b1, 4'(QV_AMO_LR)}; req.a = va; req.is_word = (size == 2'd2); end
                3: begin req.op = {1'b1, 4'(QV_AMO_SC)}; req.a = va; req.b = data; req.is_word = (size == 2'd2); end
                default: begin req.op = {1'b1, 4'(QV_AMO_ADD)}; req.a = va; req.b = data; req.is_word = (size == 2'd2); end
            endcase
            @(posedge clk); #1;
            req = '0;
            // a different op at the head first: nothing at all may go out, PTE reads included
            @(negedge clk);
            head_valid = 1'b1; head_tag = tg + 1'b1;
            repeat (delay) begin
                @(posedge clk); #1;
                check({name, ": nothing on the bus before the head"}, {63'b0, d_bus_cyc}, 64'd0);
            end
            @(negedge clk);
            head_tag = tg;
            got_wb = 1'b0;
            for (c = 0; c < 400 && !got_wb; c++) begin
                #1;
                if (wb.valid) begin
                    got_wb = 1'b1; wb_value = wb.value;
                    check({name, ": wb tag"}, {60'b0, wb.tag}, {60'b0, tg});
                    t_xcpt = res.xcpt; t_cause = res.cause; t_tval = res.tval; t_vaddr = res.vaddr; t_mem_addr = res.mem_addr;
                end
                @(posedge clk);
            end
            #1;
            head_valid = 1'b0;
            repeat (3) begin @(posedge clk); #1; end
            t_done = got_wb; t_pte = pte_reads; t_data = data_accs; t_rd = wb_value;

            // ---- the checks ----
            check({name, ": completed"}, b(got_wb), 64'd1);
            check({name, ": slot free again"}, b(free), 64'd1);
            check({name, ": exception"}, b(res.xcpt), b(exp_xcpt));
            if (exp_xcpt) begin
                check({name, ": cause"}, {60'b0, res.cause}, {60'b0, exp_cause});
                check({name, ": tval is the virtual address"}, res.tval, va);
                check({name, ": rd = 0 on a fault"}, wb_value, 64'd0);
            end else begin
                check({name, ": rd"}, wb_value, exp_rd);
                if (!(kind == 3 && exp_rd == 64'd1)) begin
                    check({name, ": vaddr is the virtual address"}, res.vaddr, va);
                    check({name, ": RVFI memory address is the physical dword"}, res.mem_addr, {exp_pa[63:3], 3'b000});
                end
            end
            // (the model knows the PTE reads of a walk from an empty TLB; without the flush a hit may save them)
            if (check_pte_reads && flush_tlb_first) check({name, ": PTE reads"}, 64'(pte_reads), 64'(exp_pte));
            check({name, ": data accesses"}, 64'(data_accs), 64'(exp_data));
            check({name, ": data writes"}, 64'(data_writes), 64'(exp_writes));
            // memory afterwards
            if (!exp_xcpt && exp_data > 0 && (kind == 1 || kind == 3 || kind == 4)) begin
                if (kind == 4) begin
                    newv = (size == 2'd2) ? {{32{(old[31:0] + data[31:0]) >> 31}}, old[31:0] + data[31:0]} : old + data;
                    // the new value goes into the lane of the address
                    gold_write(exp_pa, sel, ((size == 2'd2) ? {32'b0, newv[31:0]} : newv) << {exp_pa[2:0], 3'b000});
                end else begin
                    gold_write(exp_pa, sel, data << {exp_pa[2:0], 3'b000});
                end
            end
            check({name, ": the data dword in memory"}, mem[16 * 512 + gidx({exp_pa[63:3], 3'b000})],
                  gold[gidx({exp_pa[63:3], 3'b000})]);
        end
    endtask


    function automatic logic [43:0] resolved(input logic [43:0] raw, input logic [1:0] level, input logic [63:0] va);
        if (level == 2'd0) return raw;
        if (level == 2'd1) return {raw[43:9], va[20:12]};
        return {raw[43:18], va[29:21], va[20:12]};
    endfunction

    // ---------------- the competing fetch-side client ----------------
    bit f_traffic = 1'b0;
    always @(posedge clk) begin
        f_cancel <= 1'b0;
        if (f_traffic) begin
            if (!f_req) begin
                if (($urandom % 12) == 0) begin
                    f_req <= 1'b1;
                    f_va  <= va_of(9'd1, 9'd2, 9'($urandom % 8), 12'h0);
                    f_priv <= ($urandom % 4 == 0) ? 2'b00 : 2'b01;
                end
            end else if (w_f_done) begin
                f_req <= 1'b0;
            end else if (($urandom % 40) == 0) begin
                f_req <= 1'b0; f_cancel <= 1'b1;
            end
        end else begin
            if (f_req && w_f_done) f_req <= 1'b0;
        end
    end

    // ---------------- the random sweep ----------------
    int sw_ops = 0, sw_dbg = 0;
    task automatic random_tables;
        logic [31:0] r;
        logic [63:0] pte;
        begin
            for (int i = 0; i < 512; i++) begin put(ROOT, i, 64'd0); put(L1T, i, 64'd0); put(L0T, i, 64'd0); end
            for (int i = 0; i < 8; i++) put(ROOT, i, (($urandom % 8) != 0) ? pte_of(L1T, V) : 64'd0);
            for (int i = 0; i < 8; i++) put(L1T, i, (($urandom % 8) != 0) ? pte_of(L0T, V) : 64'd0);
            put(ROOT, 1, pte_of(L1T, V)); put(L1T, 2, pte_of(L0T, V));
            for (int i = 0; i < 8; i++) begin
                r = $urandom;
                case (r[3:0])
                    0, 1, 2, 3, 4, 5: pte = pte_of(44'h10 + (r[6:4] & 3'h7), V|R|W|A|D);
                    6:  pte = pte_of(44'h10 + r[6:4], V|R|W|A|D|U);
                    7:  pte = pte_of(44'h10 + r[6:4], V|R|A);
                    8:  pte = pte_of(44'h10 + r[6:4], V|X|A);
                    9:  pte = pte_of(44'h10 + r[6:4], V|R|W|A);
                    10: pte = pte_of(44'h10 + r[6:4], V|R|W|D);
                    11: pte = 64'd0;
                    12: pte = pte_of(44'h10 + r[6:4], V|W|A|D);
                    // a page number with a high bit set: PA bit 32 and up, which the bus drops and the PMP and the RVFI address keep
                    13: pte = pte_of((44'h10 + r[6:4]) | (44'h1 << (20 + int'(r[20:16] % 24))), V|R|W|A|D);
                    default: pte = pte_of(44'h10 + r[6:4], r[15:8] | V);
                endcase
                put(L0T, i, pte);
            end
        end
    endtask

    task automatic random_op;
        logic [31:0] r1, r2, r3, r4;
        int          kind;
        logic [1:0]  size;
        logic [63:0] va, data;
        logic        sgn, res_ok;
        begin
            r1 = $urandom; r2 = $urandom; r3 = $urandom; r4 = $urandom;
            // the context
            case (r1[2:0])
                0, 1, 2, 3: begin priv = 2'b01; end
                4, 5:       begin priv = 2'b00; end
                6:          begin priv = 2'b11; mprv = 1'b1; mpp = (r3[1:0] == 0) ? 2'b00 : (r3[1:0] == 1) ? 2'b01 : (r3[1:0] == 2) ? 2'b10 : 2'b11; end
                default:    begin priv = 2'b11; mprv = 1'b0; end
            endcase
            if (r1[2:0] != 6) mprv = (r1[3] && r1[4]);
            sum = r1[5]; mxr = r1[6];
            satp_on = (r1[11:7] != 0);
            pmp_bypass = (r1[16:12] == 0);
            // the op
            kind = (r2[2:0] < 3) ? 0 : (r2[2:0] < 5) ? 1 : (r2[2:0] == 5) ? 2 : (r2[2:0] == 6) ? 3 : 4;
            size = (kind >= 2) ? ((r2[3]) ? 2'd2 : 2'd3) : r2[5:4];
            sgn = r2[6];
            // an address in the mapped region of data pages most of the time; and some in the table page range or outside it
            va = vpg(int'(r3[10:8]), r3[27:16] & 12'hFF8);
            va[2:0] = (r3[31:28] == 0) ? r3[2:0] : 3'b000;              // misaligned now and then
            if (r4[3:0] == 0) va = va_of(9'd1, 9'd2, 9'd9, 12'h8);       // an unmapped page
            if (r4[7:4] == 0) va = {r4, r3};                               // anywhere
            if (!satp_on || pmp_bypass || ((mprv && priv == 2'b11) ? mpp == 2'b11 : priv == 2'b11)) begin
                // translation off: the virtual address is the physical one, inside the data pages
                va = 64'h10000 + {r3[15:3], 3'b000} % 64'h8000 + ((r3[31:28] == 0) ? r3[2:0] : 3'b000);
            end
            data = {r4, r3};
            res_ok = (r4[11:8] < 8);
            if (kind == 3 && res_ok) begin res_valid = 1'b1; res_addr = va; end
            // errors and a denied page, sometimes, on the way or on the data
            err_addr = '1; deny_ppn = '1; err_with_ack = r4[12];
            if (r4[16:13] == 0) err_addr = {(r4[17] ? L1T : (r4[18] ? L0T : ROOT)), 12'b0} + {44'd0, r3[2:0], 3'b000};
            if (r4[22:19] == 0) deny_ppn = (r4[23] ? L1T : (r4[24] ? L0T : ROOT));
            if (r4[28:25] == 0) deny_ppn = 44'h10 + r4[31:29];            // a data page
            lat_min = 0; lat_max = r1[19:18];
            set_pmp();
            f_traffic = (r1[22:20] < 3);
            begin : rndop
                int fails0;
                fails0 = fail_count;
                run_xl("random", kind, size, sgn, va, data, res_ok, int'(r1[27:25] & 3'h3), 1'b1, 1'b1);
                if (fail_count != fails0 && sw_dbg < 6) begin
                    sw_dbg++;
                    $display("  ^ op: kind=%0d size=%0d sgn=%b va=%h data=%h res_ok=%b | priv=%0d mprv=%b mpp=%0d sum=%b mxr=%b satp_on=%b bypass=%b err=%h deny=%h f_traffic=%b | model kind=%0d beats=%0d level=%0d ppn=%h",
                             kind, size, sgn, va, data, res_ok, priv, mprv, mpp, sum, mxr, satp_on, pmp_bypass, err_addr, deny_ppn, f_traffic, m_kind, m_beats, m_level, m_ppn);
                end
            end
            sw_ops++;
            err_addr = '1; deny_ppn = '1; set_pmp();
            f_traffic = 1'b0;
        end
    endtask

    initial begin
        clear_mem();
        reset_data();
        data_map(V|R|W|A|D);
        set_pmp();
        mon_enable = 1'b0;
        repeat (4) @(posedge clk);
        #1 rst = 1'b0;
        repeat (2) @(posedge clk); #1;
        lat_min = 0; lat_max = 1;

        // ---------------- translation off ----------------
        satp_on = 1'b0;
        run_xl("Bare load: the address is physical", 0, 2'd3, 1'b1, 64'h10000 + 64'h118, 64'd0, 1'b0, 0, 1'b1, 1'b0);
        check("Bare load: no PTE read", 64'(t_pte), 64'd0);
        run_xl("Bare store", 1, 2'd2, 1'b0, 64'h10000 + 64'h204, 64'hCAFEBABE, 1'b0, 1, 1'b1, 1'b0);
        satp_on = 1'b1;
        priv = 2'b11;
        run_xl("M mode with Sv39 on: no translation", 0, 2'd3, 1'b0, 64'h10000 + 64'h300, 64'd0, 1'b0, 0, 1'b1, 1'b0);
        check("M mode: no PTE read", 64'(t_pte), 64'd0);
        priv = 2'b01;
        pmp_bypass = 1'b1;
        run_xl("Program Buffer run: no translation", 0, 2'd3, 1'b0, 64'h10000 + 64'h308, 64'd0, 1'b0, 0, 1'b1, 1'b0);
        pmp_bypass = 1'b0;
        // MPRV: M mode runs at MPP, so MPP = S translates and MPP = M does not
        priv = 2'b11; mprv = 1'b1; mpp = 2'b01;
        run_xl("MPRV with MPP = S: translated", 0, 2'd3, 1'b0, vpg(2, 12'h40), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        check("MPRV with MPP = S: three PTE reads", 64'(t_pte), 64'd3);
        mpp = 2'b11;
        run_xl("MPRV with MPP = M: not translated", 0, 2'd3, 1'b0, 64'h10000 + 64'h50, 64'd0, 1'b0, 0, 1'b1, 1'b1);
        check("MPRV with MPP = M: no PTE read", 64'(t_pte), 64'd0);
        priv = 2'b01; mprv = 1'b0;

        // ---------------- a translated load and store ----------------
        run_xl("translated load", 0, 2'd3, 1'b0, vpg(3, 12'h128), 64'd0, 1'b0, 3, 1'b1, 1'b1);
        check("translated load: three PTE reads, then one access", 64'(t_pte) * 16 + 64'(t_data), 64'd49);
        run_xl("TLB hit: another dword of the same page", 0, 2'd3, 1'b0, vpg(3, 12'h130), 64'd0, 1'b0, 0, 1'b1, 1'b0);
        check("TLB hit: no PTE read", 64'(t_pte), 64'd0);
        run_xl("translated store", 1, 2'd3, 1'b0, vpg(4, 12'h200), 64'h0123456789ABCDEF, 1'b0, 1, 1'b1, 1'b1);
        run_xl("load back what was stored", 0, 2'd3, 1'b0, vpg(4, 12'h200), 64'd0, 1'b0, 0, 1'b1, 1'b0);
        for (int sz = 0; sz < 4; sz++)
            for (int off = 0; off < 8; off += (1 << sz)) begin
                run_xl($sformatf("store sz%0d off%0d", sz, off), 1, 2'(sz), 1'b0, vpg(5, 12'h300 + 12'(off)), {$urandom, $urandom}, 1'b0, 0, 1'b1, 1'b1);
                run_xl($sformatf("load sz%0d off%0d signed", sz, off), 0, 2'(sz), 1'b1, vpg(5, 12'h300 + 12'(off)), 64'd0, 1'b0, 0, 1'b0, 1'b0);
            end

        // ---------------- misaligned: no walk ----------------
        run_xl("misaligned load: cause 4, no walk", 0, 2'd2, 1'b0, vpg(2, 12'h101), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        check("misaligned load: no PTE read", 64'(t_pte) + 64'(t_data), 64'd0);
        run_xl("misaligned store: cause 6, no walk", 1, 2'd3, 1'b0, vpg(2, 12'h104), 64'd1, 1'b0, 0, 1'b1, 1'b1);
        run_xl("misaligned LR: cause 6", 2, 2'd3, 1'b0, vpg(2, 12'h102), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        run_xl("misaligned in an unmapped page is still misaligned, not a page fault", 0, 2'd3, 1'b0, va_of(9'd7, 9'd0, 9'd0, 12'h5), 64'd0, 1'b0, 0, 1'b1, 1'b1);

        // ---------------- a failing SC: no walk, no PMP ----------------
        deny_ppn = 44'h12; set_pmp();                                  // the page the SC's address maps to is denied
        run_xl("failing SC under translation: rd = 1, no walk, no PMP check", 3, 2'd3, 1'b0, vpg(2, 12'h40), 64'h55, 1'b0, 0, 1'b1, 1'b1);
        check("failing SC: nothing went out", 64'(t_pte) + 64'(t_data), 64'd0);
        run_xl("succeeding SC to the denied page: walk, then the PMP denies the PA (cause 7)", 3, 2'd3, 1'b0, vpg(2, 12'h40), 64'h55, 1'b1, 0, 1'b1, 1'b1);
        deny_ppn = '1; set_pmp();
        run_xl("succeeding SC: walk, then the store", 3, 2'd3, 1'b0, vpg(2, 12'h48), 64'h77, 1'b1, 0, 1'b1, 1'b1);
        check("succeeding SC: three PTE reads and one write", 64'(t_pte) * 16 + 64'(t_data), 64'd49);

        // ---------------- page faults and their causes ----------------
        data_map(V|R|A);                                               // read-only, D clear
        run_xl("load from a read-only page: fine", 0, 2'd3, 1'b0, vpg(1, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        run_xl("store to a read-only page: cause 15", 1, 2'd3, 1'b0, vpg(1, 12'h8), 64'd9, 1'b0, 0, 1'b1, 1'b1);
        run_xl("LR from a read-only page: fine", 2, 2'd3, 1'b0, vpg(1, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        run_xl("SC to a read-only page: cause 15", 3, 2'd3, 1'b0, vpg(1, 12'h8), 64'd9, 1'b1, 0, 1'b1, 1'b1);
        run_xl("AMO to a read-only page: cause 15", 4, 2'd3, 1'b0, vpg(1, 12'h8), 64'd9, 1'b0, 0, 1'b1, 1'b1);
        data_map(V|W|A|D);                                             // W without R: malformed
        run_xl("load from a malformed page: cause 13", 0, 2'd3, 1'b0, vpg(1, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        run_xl("LR from a malformed page: cause 13 (not 15, not 5/7)", 2, 2'd3, 1'b0, vpg(1, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        data_map(V|R|W|A);                                             // D clear
        run_xl("load from a D-clear page: fine", 0, 2'd2, 1'b0, vpg(1, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        run_xl("store to a D-clear page: cause 15 (Svade)", 1, 2'd2, 1'b0, vpg(1, 12'h8), 64'd9, 1'b0, 0, 1'b1, 1'b1);
        data_map(V|R|W|A|D);
        run_xl("load from an unmapped page: cause 13", 0, 2'd3, 1'b0, va_of(9'd1, 9'd2, 9'd20, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        run_xl("store to a non-canonical address: cause 15 after one PTE read", 1, 2'd3, 1'b0, 64'h0000_0080_0000_0000 | vpg(1, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        check("non-canonical: one PTE read", 64'(t_pte), 64'd1);

        // ---------------- access faults from the walk ----------------
        deny_ppn = L0T; set_pmp();
        run_xl("PTE read denied by the PMP: load, cause 5", 0, 2'd3, 1'b0, vpg(2, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        check("denied table page: two PTE reads, no data access", 64'(t_pte) * 4 + 64'(t_data), 64'd8);
        run_xl("PTE read denied by the PMP: store, cause 7", 1, 2'd3, 1'b0, vpg(2, 12'h8), 64'd1, 1'b0, 0, 1'b1, 1'b1);
        run_xl("PTE read denied by the PMP: LR, cause 7", 2, 2'd3, 1'b0, vpg(2, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        deny_ppn = '1; set_pmp();
        err_addr = {L1T, 12'b0} + 56'h10; err_with_ack = 1'b1;       // the level-1 PTE read errors
        run_xl("bus error on a PTE read: load, cause 5", 0, 2'd3, 1'b0, vpg(2, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        run_xl("bus error on a PTE read: AMO, cause 7", 4, 2'd3, 1'b0, vpg(2, 12'h8), 64'd1, 1'b0, 0, 1'b1, 1'b1);
        err_addr = '1; err_with_ack = 1'b0;

        // ---------------- the PMP judges the physical address ----------------
        deny_ppn = 44'h12; set_pmp();                                  // physical page 0x12, i.e. virtual page 2
        run_xl("load from a mapped page whose PA is denied: cause 5, PTE reads went out", 0, 2'd3, 1'b0, vpg(2, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        check("PA denied: three PTE reads, no data access", 64'(t_pte) * 16 + 64'(t_data), 64'd48);
        run_xl("store to it: cause 7", 1, 2'd3, 1'b0, vpg(2, 12'h8), 64'd1, 1'b0, 0, 1'b1, 1'b1);
        run_xl("another page is fine", 0, 2'd3, 1'b0, vpg(3, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);
        deny_ppn = '1; set_pmp();

        // ---------------- an AMO is translated once ----------------
        run_xl("AMOADD.D: translated once, read then write", 4, 2'd3, 1'b0, vpg(6, 12'h38), 64'd5, 1'b0, 0, 1'b1, 1'b1);
        check("AMO: three PTE reads and two data accesses", 64'(t_pte) * 16 + 64'(t_data), 64'd50);
        run_xl("AMOADD.W: translated once", 4, 2'd2, 1'b0, vpg(6, 12'h3C), 64'd7, 1'b0, 0, 1'b1, 1'b1);
        run_xl("LR then the page-fault-free SC", 2, 2'd3, 1'b0, vpg(6, 12'h40), 64'd0, 1'b0, 0, 1'b1, 1'b1);

        // ---------------- a flush while the walk is pending ----------------
        lat_min = 2; lat_max = 3;
        begin : flush_walk
            logic [QV_ROB_TAG_W-1:0] tg;
            sfence = 1'b1; @(posedge clk); #1; sfence = 1'b0;
            @(negedge clk); #1;
            tg = next_tag; next_tag = next_tag + 1'b1;
            req = '0; req.valid = 1'b1; req.tag = tg; req.op = {1'b0, 1'b0, 1'b0, 2'd3}; req.a = vpg(3, 12'h8); req.b = 64'd0;
            @(posedge clk); #1; req = '0;
            @(negedge clk); head_valid = 1'b1; head_tag = tg;
            repeat (5) begin @(posedge clk); #1; end                 // the walk is under way
            @(negedge clk); flush = 1'b1; head_valid = 1'b0;
            @(posedge clk); #1; flush = 1'b0;
            check("flush while translating: the slot is free", b(free), 64'd1);
            repeat (40) begin @(posedge clk); #1; end
            check("flush while translating: the walker went idle (no beat in flight)", b(ptw_beat), 64'd0);
        end
        run_xl("after the flushed op: a normal op works", 0, 2'd3, 1'b0, vpg(4, 12'h8), 64'd0, 1'b0, 0, 1'b1, 1'b1);

        // ---------------- a flush while the walk is pending, and the next op at once ----------------
        // The flushed op's walk goes on to its end (a beat is never abandoned) but its answer must not reach the next
        // op, which asks for the walker right away: A (vpn1 = 6, an empty level-1 entry, or a bus error on that read)
        // is cancelled after k cycles, B (a good page) follows with no SFENCE.VMA in between.
        lat_min = 3; lat_max = 4;
        for (int variant = 0; variant < 2; variant++)
            for (int k = 1; k <= 18; k++) begin : flush_next
                logic [QV_ROB_TAG_W-1:0] tg;
                sfence = 1'b1; @(posedge clk); #1; sfence = 1'b0;
                err_addr = (variant == 1) ? ({L1T, 12'b0} + 56'h30) : '1;       // L1T[6]
                err_with_ack = 1'b0;
                @(negedge clk); #1;
                tg = next_tag; next_tag = next_tag + 1'b1;
                req = '0; req.valid = 1'b1; req.tag = tg; req.op = {1'b0, 1'b0, 1'b0, 2'd3}; req.a = va_of(9'd1, 9'd6, 9'd0, 12'h8);
                req.b = 64'd0;
                @(posedge clk); #1; req = '0;
                @(negedge clk); head_valid = 1'b1; head_tag = tg;
                repeat (k) begin @(posedge clk); #1; end
                @(negedge clk); flush = 1'b1; head_valid = 1'b0;
                @(posedge clk); #1; flush = 1'b0;
                run_xl($sformatf("variant %0d, flushed after %0d cycles: the next op", variant, k), 0, 2'd3, 1'b0,
                       vpg(4, 12'h40), 64'd0, 1'b0, 0, 1'b0, 1'b0);
                repeat (30) begin @(posedge clk); #1; end
                check($sformatf("variant %0d, flushed after %0d cycles: the walker went idle", variant, k), b(ptw_beat), 64'd0);
            end
        err_addr = '1;
        lat_min = 0; lat_max = 1;

        // ---------------- the page number is carried whole ----------------
        // PPN bits 20 and up are PA bits 32 and up: the bus drops them (the access aliases onto the data pages), the PMP and
        // the RVFI address keep them -- bit 20 is below the PMP's 8 GB window, bits 21..43 are outside it (denied)
        for (int hb = 20; hb < 44; hb++) begin
            put(L0T, 6, pte_of(44'h12 | (44'h1 << hb), V|R|W|A|D));
            run_xl($sformatf("page number bit %0d set: load", hb), 0, 2'd3, 1'b0, vpg(6, 12'h40), 64'd0, 1'b0, 0, 1'b1, 1'b1);
            run_xl($sformatf("page number bit %0d set: store", hb), 1, 2'd3, 1'b0, vpg(6, 12'h48), {$urandom, $urandom}, 1'b0, 0, 1'b1, 1'b1);
        end
        put(L0T, 6, pte_of(44'h16, V|R|W|A|D));
        sfence = 1'b1; @(posedge clk); #1; sfence = 1'b0;
        lat_min = 0; lat_max = 1;

        // ---------------- the random sweep ----------------
        for (int m = 0; m < 12; m++) begin
            random_tables();
            sfence = 1'b1; @(posedge clk); #1; sfence = 1'b0;
            reset_data();
            for (int i = 0; i < 400; i++) random_op();
        end
        priv = 2'b01; mprv = 1'b0; satp_on = 1'b1; pmp_bypass = 1'b0;

        check("the LSU and the walker never drove the port together", 64'(port_overlaps), 64'd0);
        $display("");
        $display("qv_lsu_xl_tb: %0d passed, %0d failed (%0d random ops)", pass_count, fail_count, sw_ops);
        if (fail_count > 0) $display("qv_lsu_xl_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #2000000000;
        $display("TIMEOUT: qv_lsu_xl_tb");
        $finish;
    end
endmodule
