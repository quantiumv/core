// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: the Trigger Module (Milestone 9 groundwork) -- 2 fixed
 * mcontrol6 comparator slots, execute-address-match only. Driven through
 * dm_core_harness.sv's own DMI backdoor register interface, exactly like
 * testbench/dm_tb.sv's own scenarios, using real Access Register CSR
 * transfers to configure tselect/tdata1/tdata2 -- NOT a hierarchical
 * backdoor poke (deliberate deviation from core_debug_halt_tb.sv's own
 * M4-era precedent, see this milestone's own plan for why: by M9 the
 * real DM/Access-Register path fully exists, is strictly more realistic,
 * is the only way to reach the Program Buffer interaction scenario at
 * all, and additionally exercises trigger_csr_violation's own
 * Debug-Mode gate for real, which a backdoor poke would silently bypass).
 *
 * dut_trig_debug proves the primary, fully-supported case: action=1
 * (Debug Mode entry) on an ordinary ALU instruction's own execute
 * address -- the matched instruction's OWN register write is genuinely
 * suppressed (spec's "timing=0/before" requirement), dcsr.cause==2,
 * dpc==the matched address.
 *
 * dut_trig_exception proves action=0 (a real synchronous Breakpoint
 * exception, cause=3, instead of Debug Mode entry) -- mcause/mtval/mepc
 * report correctly, the matched instruction's own register write is
 * STILL suppressed (via instr_faulted's existing trap_taken term), and
 * the program genuinely continues afterward via a real installed mtvec
 * handler, never entering Debug Mode.
 *
 * dut_trig_priv proves the privilege-enable bits are real: a trigger
 * configured for u-mode only, while the program runs entirely in
 * M-mode, never fires.
 *
 * dut_trig_slots proves both comparator slots fire independently at
 * their own distinct addresses, with no cross-triggering -- resuming
 * past a fired slot requires disabling it first (execute=0), the same
 * way a real debugger single-steps past a live breakpoint.
 *
 * dut_trig_warl proves the WARL clamps (match/action) through the REAL
 * DMI/Access-Register path (csr_file_tb.sv already unit-tests the same
 * clamps directly against csr_file.sv -- this is the same property
 * proven through the actual consumer path instead), and that
 * trigger_csr_violation genuinely traps an ordinary running M-mode
 * program's own attempt to write tdata1 directly (mcause==2, illegal
 * instruction).
 *
 * dut_trig_progbuf proves the progbuf-suppression design: a trigger
 * configured to watch the address pc will actually visit during a real
 * Program Buffer run (pc keeps advancing off its own commit_now-gated
 * always_ff even while debug_progbuf_active, starting from the halted
 * dpc and advancing by each progbuf instruction's own length) never
 * fires -- no spurious extra halt, no abstractcs.cmderr==3.
 */
module core_trigger_tb;

    logic clk = 0;
    always #5 clk = ~clk;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    localparam [6:0] DMI_DATA0        = 7'h04;
    localparam [6:0] DMI_DATA1        = 7'h05;
    localparam [6:0] DMI_DMCONTROL    = 7'h10;
    localparam [6:0] DMI_ABSTRACTCS   = 7'h16;
    localparam [6:0] DMI_COMMAND      = 7'h17;

    localparam [11:0] CSR_TSELECT = 12'h7A0;
    localparam [11:0] CSR_TDATA1  = 12'h7A1;
    localparam [11:0] CSR_TDATA2  = 12'h7A2;
    localparam [11:0] CSR_DCSR    = 12'h7B0;
    localparam [11:0] CSR_MCAUSE  = 12'h342;
    localparam [11:0] CSR_MEPC    = 12'h341;
    localparam [11:0] CSR_MTVAL   = 12'h343;

    localparam int BUSY_RETRY_LIMIT = 100;

    // Access Register command field layout (matches dm_tb.sv's own,
    // duplicated here for the same "legible without cross-referencing
    // the DUT source" reason that file's own header states):
    // {cmdtype[8], rsvd[1], aarsize[3], aarpostincrement[1], postexec[1],
    //  transfer[1], write[1], regno[16]}.
    function automatic logic [31:0] ar_cmd(input logic wr, input logic [15:0] regno);
        return {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, wr, regno};
    endfunction
    function automatic logic [15:0] gpr_regno(input logic [4:0] gpr);
        return {11'h100, gpr};  // 0x1000 | gpr, matches dm_tb.sv's own 0x1001/0x1002 usage
    endfunction
    function automatic logic [15:0] csr_regno(input logic [11:0] csr_addr);
        return {4'b0, csr_addr};
    endfunction

    /* ------------------------------------------------------------- *
     * dut_trig_debug
     * ------------------------------------------------------------- */

    logic rst_debug = 1;
    logic [6:0]  reg_addr_debug;
    logic [31:0] reg_wdata_debug;
    logic        reg_we_debug = 1'b0;
    logic [31:0] reg_rdata_debug;
    dm_core_harness #(.NUM_WORDS(32)) dut_trig_debug (
        .clk(clk), .rst(rst_debug),
        .i_reg_addr(reg_addr_debug), .i_reg_wdata(reg_wdata_debug),
        .i_reg_we(reg_we_debug), .o_reg_rdata(reg_rdata_debug)
    );
    task automatic debug_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_debug  = addr; reg_wdata_debug = wdata; reg_we_debug = 1'b1;
        @(posedge clk); #1;
        reg_we_debug    = 1'b0;
    endtask
    task automatic debug_dmi_read(input [6:0] addr, output [31:0] rdata);
        reg_addr_debug = addr; #1; rdata = reg_rdata_debug;
    endtask
    int debug_commit_count = 0;
    always @(posedge clk) begin
        if (dut_trig_debug.core0.commit_now) debug_commit_count <= debug_commit_count + 1;
    end

    /* ------------------------------------------------------------- *
     * dut_trig_exception
     * ------------------------------------------------------------- */

    logic rst_exc = 1;
    logic [6:0]  reg_addr_exc;
    logic [31:0] reg_wdata_exc;
    logic        reg_we_exc = 1'b0;
    logic [31:0] reg_rdata_exc;
    dm_core_harness #(.NUM_WORDS(32)) dut_trig_exception (
        .clk(clk), .rst(rst_exc),
        .i_reg_addr(reg_addr_exc), .i_reg_wdata(reg_wdata_exc),
        .i_reg_we(reg_we_exc), .o_reg_rdata(reg_rdata_exc)
    );
    task automatic exc_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_exc  = addr; reg_wdata_exc = wdata; reg_we_exc = 1'b1;
        @(posedge clk); #1;
        reg_we_exc    = 1'b0;
    endtask
    task automatic exc_dmi_read(input [6:0] addr, output [31:0] rdata);
        reg_addr_exc = addr; #1; rdata = reg_rdata_exc;
    endtask
    int exc_commit_count = 0;
    always @(posedge clk) begin
        if (dut_trig_exception.core0.commit_now) exc_commit_count <= exc_commit_count + 1;
    end

    /* ------------------------------------------------------------- *
     * dut_trig_priv
     * ------------------------------------------------------------- */

    logic rst_priv = 1;
    logic [6:0]  reg_addr_priv;
    logic [31:0] reg_wdata_priv;
    logic        reg_we_priv = 1'b0;
    logic [31:0] reg_rdata_priv;
    dm_core_harness #(.NUM_WORDS(32)) dut_trig_priv (
        .clk(clk), .rst(rst_priv),
        .i_reg_addr(reg_addr_priv), .i_reg_wdata(reg_wdata_priv),
        .i_reg_we(reg_we_priv), .o_reg_rdata(reg_rdata_priv)
    );
    task automatic priv_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_priv  = addr; reg_wdata_priv = wdata; reg_we_priv = 1'b1;
        @(posedge clk); #1;
        reg_we_priv    = 1'b0;
    endtask
    task automatic priv_dmi_read(input [6:0] addr, output [31:0] rdata);
        reg_addr_priv = addr; #1; rdata = reg_rdata_priv;
    endtask
    int priv_commit_count = 0;
    always @(posedge clk) begin
        if (dut_trig_priv.core0.commit_now) priv_commit_count <= priv_commit_count + 1;
    end

    /* ------------------------------------------------------------- *
     * dut_trig_slots
     * ------------------------------------------------------------- */

    logic rst_slots = 1;
    logic [6:0]  reg_addr_slots;
    logic [31:0] reg_wdata_slots;
    logic        reg_we_slots = 1'b0;
    logic [31:0] reg_rdata_slots;
    dm_core_harness #(.NUM_WORDS(32)) dut_trig_slots (
        .clk(clk), .rst(rst_slots),
        .i_reg_addr(reg_addr_slots), .i_reg_wdata(reg_wdata_slots),
        .i_reg_we(reg_we_slots), .o_reg_rdata(reg_rdata_slots)
    );
    task automatic slots_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_slots  = addr; reg_wdata_slots = wdata; reg_we_slots = 1'b1;
        @(posedge clk); #1;
        reg_we_slots    = 1'b0;
    endtask
    task automatic slots_dmi_read(input [6:0] addr, output [31:0] rdata);
        reg_addr_slots = addr; #1; rdata = reg_rdata_slots;
    endtask
    int slots_commit_count = 0;
    always @(posedge clk) begin
        if (dut_trig_slots.core0.commit_now) slots_commit_count <= slots_commit_count + 1;
    end

    /* ------------------------------------------------------------- *
     * dut_trig_warl
     * ------------------------------------------------------------- */

    logic rst_warl = 1;
    logic [6:0]  reg_addr_warl;
    logic [31:0] reg_wdata_warl;
    logic        reg_we_warl = 1'b0;
    logic [31:0] reg_rdata_warl;
    dm_core_harness #(.NUM_WORDS(32)) dut_trig_warl (
        .clk(clk), .rst(rst_warl),
        .i_reg_addr(reg_addr_warl), .i_reg_wdata(reg_wdata_warl),
        .i_reg_we(reg_we_warl), .o_reg_rdata(reg_rdata_warl)
    );
    task automatic warl_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_warl  = addr; reg_wdata_warl = wdata; reg_we_warl = 1'b1;
        @(posedge clk); #1;
        reg_we_warl    = 1'b0;
    endtask
    task automatic warl_dmi_read(input [6:0] addr, output [31:0] rdata);
        reg_addr_warl = addr; #1; rdata = reg_rdata_warl;
    endtask
    int warl_commit_count = 0;
    always @(posedge clk) begin
        if (dut_trig_warl.core0.commit_now) warl_commit_count <= warl_commit_count + 1;
    end

    /* ------------------------------------------------------------- *
     * dut_trig_progbuf
     * ------------------------------------------------------------- */

    logic rst_pb = 1;
    logic [6:0]  reg_addr_pb;
    logic [31:0] reg_wdata_pb;
    logic        reg_we_pb = 1'b0;
    logic [31:0] reg_rdata_pb;
    dm_core_harness #(.NUM_WORDS(32)) dut_trig_progbuf (
        .clk(clk), .rst(rst_pb),
        .i_reg_addr(reg_addr_pb), .i_reg_wdata(reg_wdata_pb),
        .i_reg_we(reg_we_pb), .o_reg_rdata(reg_rdata_pb)
    );
    task automatic pb_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_pb  = addr; reg_wdata_pb = wdata; reg_we_pb = 1'b1;
        @(posedge clk); #1;
        reg_we_pb    = 1'b0;
    endtask
    task automatic pb_dmi_read(input [6:0] addr, output [31:0] rdata);
        reg_addr_pb = addr; #1; rdata = reg_rdata_pb;
    endtask
    int pb_commit_count = 0;
    always @(posedge clk) begin
        if (dut_trig_progbuf.core0.commit_now) pb_commit_count <= pb_commit_count + 1;
    end
    localparam [6:0] DMI_PROGBUF0 = 7'h20;
    localparam [6:0] DMI_PROGBUF1 = 7'h21;
    localparam [6:0] DMI_PROGBUF2 = 7'h22;

    /* ------------------------------------------------------------- *
     * dut_trig_store -- proves the FSM redesign's own primary reason
     * for existing: a trigger matching a STORE instruction's own
     * address must prevent that store's REAL BUS WRITE from ever
     * happening, not just suppress a (nonexistent, for a store) register
     * writeback. A commit_now-gated redirect (the first design tried,
     * mirroring debug_ebreak_entry too literally) would only be able to
     * intercept AFTER the store's own bus transaction already completed
     * -- see trigger_debug_entry's own port comment in design/core.sv.
     * None of the other scenarios in this file exercise this (they all
     * match ordinary ALU instructions), so this is the one direct test
     * of that specific fix.
     * ------------------------------------------------------------- */

    logic rst_store = 1;
    logic [6:0]  reg_addr_store;
    logic [31:0] reg_wdata_store;
    logic        reg_we_store = 1'b0;
    logic [31:0] reg_rdata_store;
    dm_core_harness #(.NUM_WORDS(64)) dut_trig_store (
        .clk(clk), .rst(rst_store),
        .i_reg_addr(reg_addr_store), .i_reg_wdata(reg_wdata_store),
        .i_reg_we(reg_we_store), .o_reg_rdata(reg_rdata_store)
    );
    task automatic store_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_store  = addr; reg_wdata_store = wdata; reg_we_store = 1'b1;
        @(posedge clk); #1;
        reg_we_store    = 1'b0;
    endtask
    int store_commit_count = 0;
    always @(posedge clk) begin
        if (dut_trig_store.core0.commit_now) store_commit_count <= store_commit_count + 1;
    end

    initial begin
        #1;

        /* ----------------------------------------------------------- *
         * dut_trig_debug: action=1, ordinary ALU instruction match.
         * Program:
         *  0x00  addi x1,x0,10
         *  0x04  addi x0,x0,0     [nop -- safe initial halt window]
         *  0x08  addi x0,x0,0     [nop]
         *  0x0C  addi x0,x0,0     [nop]
         *  0x10  addi x2,x0,20
         *  0x14  addi x3,x0,30    <- trigger watches this address
         *  0x18  addi x4,x0,99    reached only if suppression fails
         *  0x1C  ebreak
         * ----------------------------------------------------------- */

        dut_trig_debug.sram0.memory[0] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),
                                           encode_i(32'sd10, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut_trig_debug.sram0.memory[1] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),
                                           encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM)};
        dut_trig_debug.sram0.memory[2] = {encode_i(32'sd30, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM),
                                           encode_i(32'sd20, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM)};
        dut_trig_debug.sram0.memory[3] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                           encode_i(32'sd99, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM)};

        @(posedge clk); #1;
        rst_debug = 0;

        debug_dmi_write(DMI_DMCONTROL, 32'h0000_0001);  // dmactive
        while (debug_commit_count < 1) begin
            @(posedge clk); #1;
        end
        debug_dmi_write(DMI_DMCONTROL, 32'h8000_0001);  // haltreq
        fork
            wait (dut_trig_debug.core0.o_debug_mode === 1'b1);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_debug never reached its initial halt");
                $finish;
            end
        join_any
        disable fork;
        #1;

        // Configure slot 0: tselect=0, tdata2=0x14, tdata1: action=1
        // (Debug Mode entry), m=1, execute=1.
        debug_dmi_write(DMI_DATA0, 32'd0);
        debug_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TSELECT)));
        debug_dmi_write(DMI_DATA0, 32'h0000_0014);
        debug_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA2)));
        debug_dmi_write(DMI_DATA0, (32'd1 << 12) | (32'd1 << 6) | (32'd1 << 2));  // action=1,m=1,execute=1
        debug_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA1)));

        debug_dmi_write(DMI_DMCONTROL, 32'h4000_0001);  // resumereq
        fork
            wait (dut_trig_debug.core0.o_debug_mode === 1'b1
                  && dut_trig_debug.core0.state === dut_trig_debug.core0.S_DEBUG_HALTED
                  && dut_trig_debug.core0.dpc_w === 64'h14);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_debug never re-halted at the trigger");
                $finish;
            end
        join_any
        disable fork;
        #1;

        check("dut_trig_debug: re-halted with dcsr.cause == 2 (trigger module)",
            {61'b0, dut_trig_debug.core0.csr_file0.dcsr_q[8:6]}, 64'd2);
        check("dut_trig_debug: dpc == 0x14 (the matched address)",
            dut_trig_debug.core0.dpc_w, 64'h14);
        check("dut_trig_debug: x2 == 20 (the pre-trigger instruction ran normally)",
            dut_trig_debug.core0.regfile0.gp_registers[2], 64'd20);
        check("dut_trig_debug: x3 == 0 (the matched instruction's own write was suppressed)",
            dut_trig_debug.core0.regfile0.gp_registers[3], 64'd0);
        check("dut_trig_debug: x4 == 0 (never reached -- the hart genuinely stopped)",
            dut_trig_debug.core0.regfile0.gp_registers[4], 64'd0);

        /* ----------------------------------------------------------- *
         * dut_trig_exception: action=0, real synchronous Breakpoint
         * exception. Program:
         *  0x00  addi x28,x0,0x40   (handler address, fits a 12-bit imm)
         *  0x04  csrrw x0,mtvec,x28
         *  0x08  addi x1,x0,10
         *  0x0C  addi x0,x0,0       [nop -- safe initial halt window]
         *  0x10  addi x0,x0,0       [nop]
         *  0x14  addi x2,x0,20      <- trigger watches this address
         *  0x18  addi x3,x0,30      reached only after the handler mret's
         *  0x1C  ebreak             ebreakm armed -- clean Debug Mode stop
         *  ...
         *  0x40  addi x20,x0,1              handler: marker
         *  0x44  csrrs x21,mepc,x0           x21 = mepc (== matched addr)
         *  0x48  csrrs x22,mcause,x0         x22 = mcause
         *  0x4C  csrrs x23,mtval,x0          x23 = mtval
         *  0x50  addi x24,x21,4              skip the trapped instruction
         *  0x54  csrrw x0,mepc,x24
         *  0x58  mret
         * ----------------------------------------------------------- */

        dut_trig_exception.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                               encode_i(32'sd64, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_trig_exception.sram0.memory[1] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),
                                               encode_i(32'sd10, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut_trig_exception.sram0.memory[2] = {encode_i(32'sd20, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                                               encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM)};
        dut_trig_exception.sram0.memory[3] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                               encode_i(32'sd30, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM)};
        dut_trig_exception.sram0.memory[8] = {encode_csr(CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd21, `OPC_SYSTEM),
                                               encode_i(32'sd1, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM)};
        dut_trig_exception.sram0.memory[9] = {encode_csr(CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd23, `OPC_SYSTEM),
                                               encode_csr(CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd22, `OPC_SYSTEM)};
        dut_trig_exception.sram0.memory[10] = {encode_csr(CSR_MEPC, 5'd24, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                                encode_i(32'sd4, 5'd21, 3'b000, 5'd24, `OPC_OP_IMM)};
        dut_trig_exception.sram0.memory[11] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),
                                                `INSTR_HEX_MRET};

        @(posedge clk); #1;
        rst_exc = 0;

        exc_dmi_write(DMI_DMCONTROL, 32'h0000_0001);
        while (exc_commit_count < 1) begin
            @(posedge clk); #1;
        end
        exc_dmi_write(DMI_DMCONTROL, 32'h8000_0001);  // haltreq
        fork
            wait (dut_trig_exception.core0.o_debug_mode === 1'b1);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_exception never reached its initial halt");
                $finish;
            end
        join_any
        disable fork;
        #1;

        // Configure slot 0: action=0 (real exception), m=1, execute=1.
        exc_dmi_write(DMI_DATA0, 32'd0);
        exc_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TSELECT)));
        exc_dmi_write(DMI_DATA0, 32'h0000_0014);
        exc_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA2)));
        exc_dmi_write(DMI_DATA0, (32'd0 << 12) | (32'd1 << 6) | (32'd1 << 2));  // action=0,m=1,execute=1
        exc_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA1)));

        // Arm dcsr.ebreakm so the program's own TRAILING ebreak (reached
        // only after the handler successfully mret's) gives a clean
        // Debug Mode stop, matching this file's own established idiom
        // for "let the program run to genuine completion" scenarios.
        exc_dmi_write(DMI_DATA0, 32'h0000_8000);  // dcsr.ebreakm (bit 15)
        exc_dmi_write(DMI_DATA1, 32'd0);
        exc_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_DCSR)));

        exc_dmi_write(DMI_DMCONTROL, 32'h4000_0001);  // resumereq
        fork
            wait (dut_trig_exception.core0.o_debug_mode === 1'b1
                  && dut_trig_exception.core0.state === dut_trig_exception.core0.S_DEBUG_HALTED
                  && dut_trig_exception.core0.dpc_w === 64'h1C);
            begin
                repeat (4000) @(posedge clk);
                $display("TIMEOUT: dut_trig_exception never reached its final EBREAK");
                $finish;
            end
        join_any
        disable fork;
        #1;

        check("dut_trig_exception: x1 == 10 (ran before the trap)",
            dut_trig_exception.core0.regfile0.gp_registers[1], 64'd10);
        check("dut_trig_exception: x2 == 0 (the matched instruction's own write was suppressed)",
            dut_trig_exception.core0.regfile0.gp_registers[2], 64'd0);
        check("dut_trig_exception: x3 == 30 (ran after the handler resumed past the trap)",
            dut_trig_exception.core0.regfile0.gp_registers[3], 64'd30);
        check("dut_trig_exception: x20 == 1 (the real mtvec handler genuinely ran)",
            dut_trig_exception.core0.regfile0.gp_registers[20], 64'd1);
        check("dut_trig_exception: x21 == 0x14 (mepc captured the matched address)",
            dut_trig_exception.core0.regfile0.gp_registers[21], 64'h14);
        check("dut_trig_exception: x22 == 3 (mcause == Breakpoint)",
            dut_trig_exception.core0.regfile0.gp_registers[22], 64'd3);
        check("dut_trig_exception: x23 == 0x14 (mtval == the matched address)",
            dut_trig_exception.core0.regfile0.gp_registers[23], 64'h14);
        check("dut_trig_exception: final dcsr.cause == 1 (ebreak, not trigger) -- the trap genuinely never entered Debug Mode",
            {61'b0, dut_trig_exception.core0.csr_file0.dcsr_q[8:6]}, 64'd1);

        /* ----------------------------------------------------------- *
         * dut_trig_priv: u-mode-only trigger, program runs entirely in
         * M-mode -- must never fire.
         * Program:
         *  0x00  addi x1,x0,10
         *  0x04  addi x0,x0,0    [nop]
         *  0x08  addi x2,x0,20   <- trigger watches this address (u=1 only)
         *  0x0C  ebreak
         * ----------------------------------------------------------- */

        dut_trig_priv.sram0.memory[0] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),
                                          encode_i(32'sd10, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut_trig_priv.sram0.memory[1] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                          encode_i(32'sd20, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM)};

        @(posedge clk); #1;
        rst_priv = 0;

        priv_dmi_write(DMI_DMCONTROL, 32'h0000_0001);
        while (priv_commit_count < 1) begin
            @(posedge clk); #1;
        end
        priv_dmi_write(DMI_DMCONTROL, 32'h8000_0001);
        fork
            wait (dut_trig_priv.core0.o_debug_mode === 1'b1);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_priv never reached its initial halt");
                $finish;
            end
        join_any
        disable fork;
        #1;

        priv_dmi_write(DMI_DATA0, 32'd0);
        priv_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TSELECT)));
        priv_dmi_write(DMI_DATA0, 32'h0000_0008);
        priv_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA2)));
        priv_dmi_write(DMI_DATA0, (32'd1 << 12) | (32'd1 << 3) | (32'd1 << 2));  // action=1, u=1 ONLY, execute=1
        priv_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA1)));

        priv_dmi_write(DMI_DATA0, 32'h0000_8000);  // dcsr.ebreakm
        priv_dmi_write(DMI_DATA1, 32'd0);
        priv_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_DCSR)));

        priv_dmi_write(DMI_DMCONTROL, 32'h4000_0001);  // resumereq
        fork
            wait (dut_trig_priv.core0.o_debug_mode === 1'b1
                  && dut_trig_priv.core0.state === dut_trig_priv.core0.S_DEBUG_HALTED
                  && dut_trig_priv.core0.dpc_w === 64'hC);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_priv never reached its own EBREAK");
                $finish;
            end
        join_any
        disable fork;
        #1;

        check("dut_trig_priv: dcsr.cause == 1 (ebreak, not the u-only trigger)",
            {61'b0, dut_trig_priv.core0.csr_file0.dcsr_q[8:6]}, 64'd1);
        check("dut_trig_priv: x1 == 10", dut_trig_priv.core0.regfile0.gp_registers[1], 64'd10);
        check("dut_trig_priv: x2 == 20 (the M-mode-only trigger never fired against M-mode code)",
            dut_trig_priv.core0.regfile0.gp_registers[2], 64'd20);

        /* ----------------------------------------------------------- *
         * dut_trig_slots: both slots, independent addresses. Program:
         *  0x00  addi x1,x0,10
         *  0x04  addi x0,x0,0     [nop]
         *  0x08  addi x2,x0,20    <- slot 0 watches this address
         *  0x0C  addi x0,x0,0     [nop]
         *  0x10  addi x3,x0,30    <- slot 1 watches this address
         *  0x14  addi x4,x0,40
         *  0x18  ebreak
         * ----------------------------------------------------------- */

        dut_trig_slots.sram0.memory[0] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),
                                           encode_i(32'sd10, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut_trig_slots.sram0.memory[1] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),
                                           encode_i(32'sd20, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM)};
        dut_trig_slots.sram0.memory[2] = {encode_i(32'sd40, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM),
                                           encode_i(32'sd30, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM)};
        dut_trig_slots.sram0.memory[3] = {32'h0,
                                           {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};

        @(posedge clk); #1;
        rst_slots = 0;

        slots_dmi_write(DMI_DMCONTROL, 32'h0000_0001);
        while (slots_commit_count < 1) begin
            @(posedge clk); #1;
        end
        slots_dmi_write(DMI_DMCONTROL, 32'h8000_0001);
        fork
            wait (dut_trig_slots.core0.o_debug_mode === 1'b1);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_slots never reached its initial halt");
                $finish;
            end
        join_any
        disable fork;
        #1;

        // Slot 0 -> 0x08, slot 1 -> 0x10, both action=1/m=1/execute=1.
        slots_dmi_write(DMI_DATA0, 32'd0);
        slots_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TSELECT)));
        slots_dmi_write(DMI_DATA0, 32'h0000_0008);
        slots_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA2)));
        slots_dmi_write(DMI_DATA0, (32'd1 << 12) | (32'd1 << 6) | (32'd1 << 2));
        slots_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA1)));

        slots_dmi_write(DMI_DATA0, 32'd1);
        slots_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TSELECT)));
        slots_dmi_write(DMI_DATA0, 32'h0000_0010);
        slots_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA2)));
        slots_dmi_write(DMI_DATA0, (32'd1 << 12) | (32'd1 << 6) | (32'd1 << 2));
        slots_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA1)));

        slots_dmi_write(DMI_DMCONTROL, 32'h4000_0001);  // resumereq
        fork
            wait (dut_trig_slots.core0.o_debug_mode === 1'b1
                  && dut_trig_slots.core0.state === dut_trig_slots.core0.S_DEBUG_HALTED
                  && dut_trig_slots.core0.dpc_w === 64'h8);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_slots never hit slot 0");
                $finish;
            end
        join_any
        disable fork;
        #1;
        check("dut_trig_slots: slot 0 fired -- dpc == 0x08", dut_trig_slots.core0.dpc_w, 64'h8);
        check("dut_trig_slots: x2 == 0 (slot 0's own match suppressed the write)",
            dut_trig_slots.core0.regfile0.gp_registers[2], 64'd0);

        // Disable slot 0 (execute=0) so resuming makes forward progress
        // instead of immediately re-matching the same instruction --
        // the same "single-step past a live breakpoint" idiom a real
        // debugger uses.
        slots_dmi_write(DMI_DATA0, 32'd0);
        slots_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TSELECT)));
        slots_dmi_write(DMI_DATA0, (32'd1 << 12) | (32'd1 << 6));  // execute=0 now
        slots_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA1)));

        slots_dmi_write(DMI_DMCONTROL, 32'h4000_0001);  // resumereq
        fork
            wait (dut_trig_slots.core0.o_debug_mode === 1'b1
                  && dut_trig_slots.core0.state === dut_trig_slots.core0.S_DEBUG_HALTED
                  && dut_trig_slots.core0.dpc_w === 64'h10);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_slots never hit slot 1");
                $finish;
            end
        join_any
        disable fork;
        #1;
        check("dut_trig_slots: slot 1 fired -- dpc == 0x10 (not re-triggered by slot 0)",
            dut_trig_slots.core0.dpc_w, 64'h10);
        check("dut_trig_slots: x2 == 20 (slot 0's own instruction ran fine once disabled)",
            dut_trig_slots.core0.regfile0.gp_registers[2], 64'd20);
        check("dut_trig_slots: x3 == 0 (slot 1's own match suppressed the write)",
            dut_trig_slots.core0.regfile0.gp_registers[3], 64'd0);

        // Disable slot 1 too, arm ebreakm, resume to genuine completion.
        slots_dmi_write(DMI_DATA0, 32'd1);
        slots_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TSELECT)));
        slots_dmi_write(DMI_DATA0, (32'd1 << 12) | (32'd1 << 6));  // execute=0 now
        slots_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA1)));

        slots_dmi_write(DMI_DATA0, 32'h0000_8000);
        slots_dmi_write(DMI_DATA1, 32'd0);
        slots_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_DCSR)));

        slots_dmi_write(DMI_DMCONTROL, 32'h4000_0001);
        fork
            wait (dut_trig_slots.core0.o_debug_mode === 1'b1
                  && dut_trig_slots.core0.state === dut_trig_slots.core0.S_DEBUG_HALTED
                  && dut_trig_slots.core0.dpc_w === 64'h18);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_slots never reached its own EBREAK");
                $finish;
            end
        join_any
        disable fork;
        #1;
        check("dut_trig_slots: final -- x3 == 30 (ran once slot 1 disabled)",
            dut_trig_slots.core0.regfile0.gp_registers[3], 64'd30);
        check("dut_trig_slots: final -- x4 == 40", dut_trig_slots.core0.regfile0.gp_registers[4], 64'd40);
        check("dut_trig_slots: final -- dcsr.cause == 1 (ebreak)",
            {61'b0, dut_trig_slots.core0.csr_file0.dcsr_q[8:6]}, 64'd1);

        /* ----------------------------------------------------------- *
         * dut_trig_warl: WARL clamps through the real DMI path, plus
         * trigger_csr_violation gating an ordinary running program.
         * Program:
         *  0x00  addi x1,x0,10
         *  0x04  addi x0,x0,0     [nop -- safe initial halt window]
         *  0x08  csrrw x0,tdata1,x1   real, running M-mode software
         *                              attempting to write a trigger CSR
         *                              directly -- must trap illegal
         *  0x0C  addi x0,x0,0     unreachable (mtvec unconfigured -> the
         *                          trap loops back to address 0 instead)
         * ----------------------------------------------------------- */

        dut_trig_warl.sram0.memory[0] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),
                                          encode_i(32'sd10, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut_trig_warl.sram0.memory[1] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),
                                          encode_csr(CSR_TDATA1, 5'd1, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};

        @(posedge clk); #1;
        rst_warl = 0;

        warl_dmi_write(DMI_DMCONTROL, 32'h0000_0001);
        while (warl_commit_count < 1) begin
            @(posedge clk); #1;
        end
        warl_dmi_write(DMI_DMCONTROL, 32'h8000_0001);
        fork
            wait (dut_trig_warl.core0.o_debug_mode === 1'b1);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_warl never reached its initial halt");
                $finish;
            end
        join_any
        disable fork;
        #1;

        // WARL clamp round trip through the real DMI/Access-Register path.
        // A settling edge is inserted between each command word (Access
        // Register commands take a real cycle to complete -- abstractcs.
        // busy asserts the cycle right after a legal command and clears
        // one cycle later, same timing dm_tb.sv's own busy-collision test
        // documents; issuing a SECOND command before that window elapses
        // gets rejected with cmderr=1, silently leaving DATA0 stale).
        // Every OTHER command sequence in this file happened to have a
        // natural 2-edge gap already (an intervening DATA0 write between
        // consecutive commands); this WRITE-then-immediately-READ
        // sequence doesn't, so the gap has to be explicit here.
        warl_dmi_write(DMI_DATA0, 32'd0);
        warl_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TSELECT)));
        warl_dmi_write(DMI_DATA0, (32'd5 << 7) | (32'd3 << 12));  // match=5, action=3
        warl_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA1)));
        @(posedge clk); #1;
        warl_dmi_write(DMI_COMMAND, ar_cmd(1'b0, csr_regno(CSR_TDATA1)));
        begin
            logic [31:0] rd;
            warl_dmi_read(DMI_DATA0, rd);
            check("dut_trig_warl: match clamps to 0 through the real DMI path", {29'b0, rd[10:7]}, 64'd0);
            check("dut_trig_warl: action clamps to 1 through the real DMI path", {29'b0, rd[15:12]}, 64'd1);
        end

        // Resume -- the real running program's own csrrw to tdata1 must
        // trap as illegal-instruction (mcause==2), looping back to
        // address 0 (mtvec unconfigured) repeatedly. mcause/mepc are
        // sticky, so halting again at ANY later point still reports the
        // one real trap's own values correctly.
        warl_dmi_write(DMI_DMCONTROL, 32'h4000_0001);  // resumereq
        while (warl_commit_count < 6) begin
            @(posedge clk); #1;
        end
        warl_dmi_write(DMI_DMCONTROL, 32'h8000_0001);  // haltreq again
        fork
            wait (dut_trig_warl.core0.o_debug_mode === 1'b1);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_warl never re-halted");
                $finish;
            end
        join_any
        disable fork;
        #1;

        warl_dmi_write(DMI_COMMAND, ar_cmd(1'b0, csr_regno(CSR_MCAUSE)));
        begin
            logic [31:0] rd;
            warl_dmi_read(DMI_DATA0, rd);
            check("dut_trig_warl: mcause == 2 (illegal instruction) -- trigger_csr_violation gated the running csrrw",
                {32'b0, rd}, 64'd2);
        end
        @(posedge clk); #1;
        warl_dmi_write(DMI_COMMAND, ar_cmd(1'b0, csr_regno(CSR_MEPC)));
        begin
            logic [31:0] rd;
            warl_dmi_read(DMI_DATA0, rd);
            check("dut_trig_warl: mepc == 0x08 (the illegal csrrw's own address)", {32'b0, rd}, 64'h8);
        end

        /* ----------------------------------------------------------- *
         * dut_trig_progbuf: a trigger watching the address a real
         * Program Buffer op will execute at must never fire. pc keeps
         * advancing off its own commit_now-gated always_ff during
         * progbuf execution (starting from the halted dpc, +4 per
         * ordinary 32-bit progbuf instruction) -- the trigger below
         * targets dpc+4, the SECOND of two progbuf ADDI instructions.
         * Program: just enough for a clean initial halt.
         *  0x00  addi x1,x0,10
         *  0x04  ebreak
         * ----------------------------------------------------------- */

        dut_trig_progbuf.sram0.memory[0] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                             encode_i(32'sd10, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};

        @(posedge clk); #1;
        rst_pb = 0;

        pb_dmi_write(DMI_DMCONTROL, 32'h0000_0001);
        pb_dmi_write(DMI_DMCONTROL, 32'h8000_0001);  // haltreq -- catches it immediately, dpc==0x00
        fork
            wait (dut_trig_progbuf.core0.o_debug_mode === 1'b1);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_progbuf never reached its initial halt");
                $finish;
            end
        join_any
        disable fork;
        #1;

        // Configure the trigger at dpc+4 -- the second progbuf ADDI's
        // own expected pc, action=1, m=1, execute=1.
        begin
            logic [63:0] dpc_now;
            dpc_now = dut_trig_progbuf.core0.dpc_w;
            pb_dmi_write(DMI_DATA0, 32'd0);
            pb_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TSELECT)));
            pb_dmi_write(DMI_DATA0, dpc_now[31:0] + 32'd4);
            pb_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA2)));
            pb_dmi_write(DMI_DATA0, (32'd1 << 12) | (32'd1 << 6) | (32'd1 << 2));
            pb_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA1)));
        end

        // Program Buffer: addi x10,x0,5 ; addi x11,x0,6 ; postexec.
        pb_dmi_write(DMI_PROGBUF0, encode_i(32'sd5, 5'd0, 3'b000, 5'd10, `OPC_OP_IMM));
        pb_dmi_write(DMI_PROGBUF1, encode_i(32'sd6, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM));
        pb_dmi_write(DMI_PROGBUF2, {11'b0, 1'b1, 13'b0, `OPC_SYSTEM});  // trailing ebreak -- signals "done"
        // Access Register command: postexec=1, transfer=0, write=0, regno=0
        // -- {cmdtype[8], rsvd[1], aarsize[3], aarpostincrement[1],
        //     postexec[1], transfer[1], write[1], regno[16]}.
        pb_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 1'b0, 16'h0000});

        begin
            logic [31:0] rd;
            int tries;
            tries = 0;
            rd = 32'h0000_1000;  // seed with busy=1
            while (rd[12]) begin
                if (tries >= BUSY_RETRY_LIMIT) begin
                    $display("TIMEOUT: dut_trig_progbuf busy never cleared");
                    $finish;
                end
                @(posedge clk); #1;
                pb_dmi_read(DMI_ABSTRACTCS, rd);
                tries++;
            end
            check("dut_trig_progbuf: abstractcs.cmderr == 0 (no exception/abort -- the trigger never fired)",
                {61'b0, rd[10:8]}, 64'd0);
        end
        check("dut_trig_progbuf: o_debug_mode still 1 (never redirected by the trigger, still the ordinary halt)",
            {63'b0, dut_trig_progbuf.core0.o_debug_mode}, 64'd1);
        check("dut_trig_progbuf: x10 == 5 (progbuf's own first instruction genuinely landed)",
            dut_trig_progbuf.core0.regfile0.gp_registers[10], 64'd5);
        check("dut_trig_progbuf: x11 == 6 (progbuf's own second instruction -- at the trigger's own watched pc -- genuinely landed too)",
            dut_trig_progbuf.core0.regfile0.gp_registers[11], 64'd6);

        /* ----------------------------------------------------------- *
         * dut_trig_store: a trigger matching a STORE instruction's own
         * address must prevent its real bus write. Program:
         *  0x00  addi x5,x0,0x100   store target address
         *  0x04  addi x1,x0,0xAB    value to store
         *  0x08  addi x0,x0,0       [nop -- safe initial halt window]
         *  0x0C  sd x1,0(x5)        <- trigger watches this address
         *  0x10  ebreak
         * memory[0x100] is pre-loaded with a known sentinel BEFORE
         * running, checked to be UNCHANGED afterward.
         * ----------------------------------------------------------- */

        dut_trig_store.sram0.memory[0] = {encode_i(32'sd171, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM),
                                           encode_i(32'sd256, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM)};
        dut_trig_store.sram0.memory[1] = {encode_s(32'sd0, 5'd1, 5'd5, 3'b011, `OPC_STORE),
                                           encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM)};
        dut_trig_store.sram0.memory[2] = {32'h0,
                                           {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};
        dut_trig_store.sram0.memory[32] = 64'hDEAD_BEEF_DEAD_BEEF;  // sentinel at the store's own target (0x100)

        @(posedge clk); #1;
        rst_store = 0;

        store_dmi_write(DMI_DMCONTROL, 32'h0000_0001);
        while (store_commit_count < 1) begin
            @(posedge clk); #1;
        end
        store_dmi_write(DMI_DMCONTROL, 32'h8000_0001);  // haltreq
        fork
            wait (dut_trig_store.core0.o_debug_mode === 1'b1);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_store never reached its initial halt");
                $finish;
            end
        join_any
        disable fork;
        #1;

        store_dmi_write(DMI_DATA0, 32'd0);
        store_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TSELECT)));
        store_dmi_write(DMI_DATA0, 32'h0000_000C);
        store_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA2)));
        store_dmi_write(DMI_DATA0, (32'd1 << 12) | (32'd1 << 6) | (32'd1 << 2));  // action=1,m=1,execute=1
        store_dmi_write(DMI_COMMAND, ar_cmd(1'b1, csr_regno(CSR_TDATA1)));

        store_dmi_write(DMI_DMCONTROL, 32'h4000_0001);  // resumereq
        fork
            wait (dut_trig_store.core0.o_debug_mode === 1'b1
                  && dut_trig_store.core0.state === dut_trig_store.core0.S_DEBUG_HALTED
                  && dut_trig_store.core0.dpc_w === 64'hC);
            begin
                repeat (2000) @(posedge clk);
                $display("TIMEOUT: dut_trig_store never re-halted at the trigger");
                $finish;
            end
        join_any
        disable fork;
        #1;

        check("dut_trig_store: re-halted with dcsr.cause == 2 and dpc == 0x0C (the store's own address)",
            {61'b0, dut_trig_store.core0.csr_file0.dcsr_q[8:6]}, 64'd2);
        check("dut_trig_store: memory[0x100] is UNCHANGED -- the store's own bus write never happened",
            dut_trig_store.sram0.memory[32], 64'hDEAD_BEEF_DEAD_BEEF);

        $display("");
        $display("core_trigger_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_trigger_tb: FAILURES PRESENT");
        $finish;
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
