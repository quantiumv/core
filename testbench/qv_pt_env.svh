// SPDX-License-Identifier: MIT

/*
 * qv_pt_env.svh -- the page-table test environment shared by qv_ptw_tb and
 * qv_xlate_tb: a 128 KB memory for page tables behind a Wishbone slave with
 * random latency, bus errors and a PMP pocket; a monitor of the walker's bus
 * protocol; and a software model of the walk.
 *
 * `include'd inside the testbench module (the way check_lib.sv is), after
 * these names exist there: clk, rst, bus_cyc, bus_addr, bus_we, bus_sel, bus_dato (the master's
 * we, sel and write data), bus_dat, bus_ack, bus_err, beat, lsu_busy, pmpcfg0, pmpaddr0,
 * pmpaddr1, b(). A testbench whose master never writes ties bus_we low.
 */

    // ---------------- the memory and the slave ----------------
    localparam int MEMW = 16384;                  // dwords: 128 KB, addressed by bus_addr[16:3]
    logic [63:0] mem [0:MEMW-1];

    // slave behaviour, set per test
    int          lat_min = 0, lat_max = 0;        // extra wait cycles before the ack
    logic [55:0] err_addr = '1;                   // a PTE address whose read answers with err ('1 = none)
    bit          err_with_ack = 1'b0;             // ... together with ack
    logic [43:0] deny_ppn = '1;                   // the table page the PMP forbids reading ('1 = none)

    int          slave_wait = -1;
    logic [31:0] slave_addr;
    logic        slave_we;
    logic [7:0]  slave_sel;
    logic [63:0] slave_dato;
    bit          mon_enable = 1'b1;              // a testbench whose master shares the port with another turns the monitor off
    int          beats_total = 0;                 // rising edges of cyc
    logic [31:0] beat_log [0:63];                 // the addresses of the beats, in order
    int          beat_log_n = 0;

    always @(posedge clk) begin
        bus_ack <= 1'b0;
        bus_err <= 1'b0;
        if (rst) begin
            slave_wait <= -1;
        end else if (slave_wait >= 0) begin
            if (slave_wait == 0) begin
                bus_dat <= mem[slave_addr[16:3]];
                if ({24'b0, slave_addr} == err_addr[31:0] && err_addr != '1) begin
                    bus_err <= 1'b1;
                    bus_ack <= err_with_ack;
                end else begin
                    bus_ack <= 1'b1;
                    if (slave_we)
                        for (int i = 0; i < 8; i++)
                            if (slave_sel[i]) mem[slave_addr[16:3]][8*i +: 8] <= slave_dato[8*i +: 8];
                end
                slave_wait <= -1;
            end else begin
                slave_wait <= slave_wait - 1;
            end
        end else if (bus_cyc && !bus_ack && !bus_err) begin
            slave_addr <= {bus_addr[31:3], 3'b000};
            slave_we   <= bus_we;
            slave_sel  <= bus_sel;
            slave_dato <= bus_dato;
            slave_wait <= lat_min + ((lat_max > lat_min) ? ($urandom % (lat_max - lat_min + 1)) : 0);
        end
    end

    // ---------------- the monitor ----------------
    logic        prev_cyc = 1'b0, prev_resp = 1'b0, prev_lsu_busy = 1'b0;
    logic [31:0] prev_addr = '0;
    int          proto_errors = 0;
    int          last_rise_cycle = -1;
    int          cycle_n = 0;
    always @(posedge clk) begin
        cycle_n <= cycle_n + 1;
        if (!rst && mon_enable) begin
            // a request on the bus is never dropped before its response
            if (prev_cyc && !prev_resp && !bus_cyc && !(bus_ack || bus_err)) begin
                proto_errors++; $display("PROTOCOL: cyc dropped before the response at cycle %0d", cycle_n);
            end
            if (bus_cyc && prev_cyc && bus_addr != prev_addr) begin
                proto_errors++; $display("PROTOCOL: address changed during a beat at cycle %0d", cycle_n);
            end
            if (bus_cyc && !beat) begin
                proto_errors++; $display("PROTOCOL: cyc without o_beat at cycle %0d", cycle_n);
            end
            // cyc drops in the response cycle (wb_arbiter2 releases the grant when the granted master's cyc is low then)
            if (bus_cyc && (bus_ack || bus_err)) begin
                proto_errors++; $display("PROTOCOL: cyc still high in the response cycle %0d", cycle_n);
            end
            if (bus_cyc && !prev_cyc) begin
                beats_total++;
                last_rise_cycle <= cycle_n;
                if (prev_lsu_busy) begin
                    proto_errors++; $display("PROTOCOL: a beat started after a cycle with the LSU busy, cycle %0d", cycle_n);
                end
                if (beat_log_n < 64) begin beat_log[beat_log_n] = {bus_addr[31:3], 3'b000}; beat_log_n++; end
            end
            if (!bus_cyc && (bus_ack || bus_err) && !beat && !prev_cyc) begin
                // a response with no beat of ours in flight must be ignored: nothing to check here, the walker's
                // state is what the directed cases look at
            end
        end
        prev_cyc      <= bus_cyc;
        prev_resp     <= (bus_ack || bus_err);
        prev_addr     <= bus_addr;
        prev_lsu_busy <= lsu_busy;
    end

    // ---------------- software model of the walk ----------------
    function automatic logic model_deny(input logic [55:0] addr);
        // the PMP as the TB configures it: the pocket page (no R), then everything below 8 GB (RWX)
        if (addr + 56'd7 >= 56'h2_0000_0000) return 1'b1;
        if (deny_ppn != '1 && addr[55:12] == deny_ppn) return 1'b1;
        return 1'b0;
    endfunction

    task automatic model_judge(input logic [63:0] pte, input logic [1:0] level, input logic [63:0] va, input logic is_mem,
                               input logic wr, input logic [1:0] priv, input logic sum, input logic mxr,
                               output logic leaf, output logic fault);
        logic [43:0] full_ppn;
        logic        canonical;
        begin
            fault = 1'b0;
            leaf = pte[1] | pte[3];
            full_ppn = pte[53:10];
            canonical = 1'b1;
            for (int i = 39; i < 64; i++) if (va[i] !== va[38]) canonical = 1'b0;
            if (!canonical) fault = 1'b1;
            if (!pte[0]) fault = 1'b1;
            if (!pte[1] && pte[2]) fault = 1'b1;
            if (pte[60:54] != 7'd0 || pte[62:61] != 2'd0 || pte[63]) fault = 1'b1;
            if (leaf) begin
                if (level == 2'd2 && (full_ppn & 44'h3FFFF) != 44'd0) fault = 1'b1;
                if (level == 2'd1 && (full_ppn & 44'h001FF) != 44'd0) fault = 1'b1;
                if (is_mem) begin
                    if (pte[4]) begin
                        if (!(priv == 2'd0 || (priv == 2'd1 && sum))) fault = 1'b1;
                    end else if (priv == 2'd0) fault = 1'b1;
                    if (wr) begin
                        if (!pte[2]) fault = 1'b1;
                        if (!pte[7]) fault = 1'b1;
                    end else if (!(pte[1] || (mxr && pte[3]))) fault = 1'b1;
                end else begin
                    if (pte[4]) begin
                        if (priv == 2'd1) fault = 1'b1;
                    end else if (priv == 2'd0) fault = 1'b1;
                    if (!pte[3]) fault = 1'b1;
                end
                if (!pte[6]) fault = 1'b1;
            end else if (level == 2'd0) fault = 1'b1;
        end
    endtask

    // the model's walk: kind 0 = ok, 1 = page fault, 2 = access fault; the PTE addresses it read, in order
    int          m_kind, m_beats;
    logic [31:0] m_addrs [0:3];
    logic [1:0]  m_level;
    logic [43:0] m_ppn;
    logic [63:0] m_pte;

    task automatic model_walk(input logic [63:0] va, input logic is_mem, input logic wr, input logic [1:0] priv,
                              input logic sum, input logic mxr, input logic [43:0] root);
        logic [43:0] base;
        logic [8:0]  vpn_cur;
        logic [55:0] addr;
        logic        leaf, fault;
        int          level;
        bit          done;
        begin
            base = root; level = 2; m_beats = 0; m_kind = 0; done = 1'b0;
            m_level = 2'd0; m_ppn = '0; m_pte = '0;
            while (!done) begin
                vpn_cur = (level == 2) ? va[38:30] : (level == 1) ? va[29:21] : va[20:12];
                addr = {base, vpn_cur, 3'b000};
                if (model_deny(addr)) begin
                    m_kind = 2; done = 1'b1;
                end else begin
                    m_addrs[m_beats] = {addr[31:3], 3'b000};
                    m_beats++;
                    m_pte = mem[addr[16:3]];
                    if (err_addr != '1 && addr[31:0] == err_addr[31:0]) begin
                        m_kind = 2; done = 1'b1;
                    end else begin
                        model_judge(m_pte, level[1:0], va, is_mem, wr, priv, sum, mxr, leaf, fault);
                        if (fault) begin m_kind = 1; done = 1'b1; end
                        else if (leaf) begin m_kind = 0; m_level = level[1:0]; m_ppn = m_pte[53:10]; done = 1'b1; end
                        else begin base = m_pte[53:10]; level--; end
                    end
                end
            end
        end
    endtask

    // ---------------- table building ----------------
    function automatic logic [63:0] pte_of(input logic [43:0] ppn, input logic [7:0] f);
        return {10'b0, ppn, 2'b00, f};
    endfunction
    localparam logic [7:0] V = 8'h01, R = 8'h02, W = 8'h04, X = 8'h08, U = 8'h10, A = 8'h40, D = 8'h80;

    // physical page numbers of the tables: root 2, level-1 table 3, level-0 table 4 (PA = ppn << 12, inside the 128 KB array)
    localparam logic [43:0] ROOT = 44'd2, L1T = 44'd3, L0T = 44'd4;
    task automatic clear_mem;
        begin for (int i = 0; i < MEMW; i++) mem[i] = '0; end
    endtask
    task automatic put(input logic [43:0] table_ppn, input int idx, input logic [63:0] pte);
        begin mem[{table_ppn[4:0], 9'b0} + idx] = pte; end
    endtask
    function automatic logic [63:0] va_of(input logic [8:0] v2, input logic [8:0] v1, input logic [8:0] v0, input logic [11:0] off);
        return {25'b0, v2, v1, v0, off};
    endfunction

    // the standard map: vpn2=1 -> L1T, vpn1=2 -> L0T, vpn0=3 -> a 4 KB leaf (ppn 0x12345)
    task automatic std_map(input logic [7:0] leaf_flags);
        begin
            clear_mem();
            put(ROOT, 1, pte_of(L1T, V));
            put(L1T, 2, pte_of(L0T, V));
            put(L0T, 3, pte_of(44'h12345, leaf_flags));
        end
    endtask

    task automatic set_pmp;            // region 0 = the denied page (if any), region 1 = [0, 8 GB) rwx
        logic [7:0] c0;
        begin
            c0 = (deny_ppn != '1) ? 8'h18 : 8'h00;      // NAPOT, no permissions; or off
            pmpaddr0 = (deny_ppn != '1) ? ({20'b0, deny_ppn} << 10) | 64'h1FF : 64'd0;
            pmpaddr1 = 64'h3FFFFFFF;                    // NAPOT, 8 GB
            pmpcfg0  = {48'b0, 8'h1F, c0};
        end
    endtask

