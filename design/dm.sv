// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: dm
 *
 * Debug Module register file (Milestone 5 of the EBREAK/JTAG staged
 * plan -- see [[debug-halt-fsm-milestone]] for Milestone 4, which added
 * the halt/resume/step FSM this module now drives). Implements the
 * subset of the RISC-V Debug Specification (0.13.2/1.0) register set
 * needed for a debugger to halt/resume/step the hart and read/write a
 * GPR or CSR while it's halted (an "Access Register" abstract command,
 * cmdtype=0) -- everything else (System Bus Access, the Program Buffer,
 * Quick Access commands) gets register STORAGE now (so the shape is
 * proven once) but no functional backing until later milestones give it
 * one (M7/M8).
 *
 * NOTE ON SPEC FIDELITY: this repo has no local copy of the RISC-V
 * Debug Specification to cross-check exact bit positions against (see
 * the Milestone 5 grounding pass) -- the register addresses and the
 * functionally-load-bearing fields below (dmcontrol.dmactive/haltreq/
 * resumereq, dmstatus.version/authenticated/allhalted/anyhalted/
 * allrunning/anyrunning, abstractcs.datacount/cmderr/busy, command's
 * Access Register encoding) are implemented from memory of the spec and
 * are internally self-consistent and tested by dm_tb.sv, but several
 * dmstatus corner fields (allhavereset/anynonexistent/anyunavail/etc.)
 * are deliberately placed at reserved/best-effort positions and always
 * read 0 -- they carry no functional weight this milestone (nothing
 * reads them) and should be cross-checked against the real spec text
 * before Milestone 10's real OpenOCD integration test, not assumed
 * correct from this comment alone.
 *
 * Plain register interface, not the literal 41-bit DMI protocol: DMI's
 * own busy/sticky-error transport semantics (spec ch. 6.1) are a
 * separate concern, deliberately deferred to a future design/dm_dmi.sv
 * (Milestone 6, instantiated by the real JTAG TAP) that will translate
 * DMI read/write/nop operations into i_reg_we/i_reg_addr/i_reg_wdata
 * pulses against this module -- letting a testbench (or, later, the
 * DTM) drive this module directly with no DMI FSM in the way.
 * i_reg_we is a single-cycle enable (this codebase's own established
 * convention, e.g. register_file.sv's i_load_gpr/csr_file.sv's
 * i_csr_we) -- i_reg_wdata is only guaranteed valid the same cycle.
 * o_reg_rdata is combinational off i_reg_addr, mirroring csr_file.sv's
 * own o_csr_rdata (flat read-mux, no separate read-enable needed).
 *
 * Access Register execution is a single clock edge, not a multi-cycle
 * FSM: core0's GPR read port and CSR read port are both combinational
 * (register_file.sv/csr_file.sv), so the moment o_dm_gpr_sel/
 * o_dm_csr_addr are driven (the same cycle `command` is DMI-written),
 * i_dm_gpr_rdata/i_dm_csr_rdata already reflect the target register --
 * a READ command's data0/data1 capture and a WRITE command's actual
 * register write both land on that same next clock edge. busy_q pulses
 * for exactly the one cycle after a legal command is issued, which is
 * honest given the transfer has ALREADY completed by the time busy_q
 * reads 1 -- a debugger polling abstractcs sees a brief, real busy
 * pulse, not a lie about ongoing work.
 *
 * cmderr is real, sticky storage (RISC-V Debug Spec semantics: once
 * nonzero, further commands are refused until the debugger clears it by
 * writing 1 to the cmderr field) -- see the cmderr_q always_ff below for
 * the exact priority order (halt/resume > busy > not-supported), which
 * matches this project's own "the DM does not attempt to determine
 * whether more than one error occurred" reading of the spec.
 */
module dm (
    input logic clk,
    input logic rst,

    /*
     * Plain register interface -- see the module header above for why
     * this isn't the literal 41-bit DMI protocol.
     */
    input  logic [6:0]  i_reg_addr,
    input  logic [31:0] i_reg_wdata,
    input  logic        i_reg_we,
    output logic [31:0] o_reg_rdata,

    /*
     * Hart control/status, wired directly to core0's own Milestone 4
     * halt/resume ports -- same clock domain, no CDC needed (a real CDC
     * only becomes necessary once Milestone 6's JTAG TAP puts TCK, a
     * genuinely async clock, in the picture).
     */
    input  logic i_hart_halted,        // core0.o_debug_mode
    output logic o_debug_halt_req,     // -> core0.i_debug_halt_req (level)
    output logic o_debug_resume_req,   // -> core0.i_debug_resume_req (pulse)

    /*
     * Access Register: GPR transfer (Milestone 5's own new core0 ports).
     */
    output logic        o_dm_gpr_we,
    output logic [4:0]  o_dm_gpr_sel,
    output logic [63:0] o_dm_gpr_wdata,
    input  logic [63:0] i_dm_gpr_rdata,

    /*
     * Access Register: CSR transfer (Milestone 5's own new core0 ports).
     */
    output logic        o_dm_csr_we,
    output logic [11:0] o_dm_csr_addr,
    output logic [63:0] o_dm_csr_wdata,
    input  logic [63:0] i_dm_csr_rdata
);
    /*
     * DMI register address map (RISC-V Debug Spec 0.13.2/1.0's own 7-bit
     * DMI address space). Only the addresses this milestone gives real
     * meaning to are named individually; sbaddress0-2/sbdata0-3 and
     * progbuf0-15 are storage-only stubs (see the module header) still
     * addressed at their real spec locations so a future real debugger
     * sees the right layout even before M7/M8 give them a function.
     */
    localparam ADDR_DATA0        = 7'h04;
    localparam ADDR_DATA1        = 7'h05;
    localparam ADDR_DMCONTROL    = 7'h10;
    localparam ADDR_DMSTATUS     = 7'h11;
    localparam ADDR_HARTINFO     = 7'h12;
    localparam ADDR_ABSTRACTCS   = 7'h16;
    localparam ADDR_COMMAND      = 7'h17;
    localparam ADDR_ABSTRACTAUTO = 7'h18;
    localparam ADDR_PROGBUF_LO   = 7'h20;  // progbuf0
    localparam ADDR_PROGBUF_HI   = 7'h2F;  // progbuf15
    localparam ADDR_SBADDRESS3   = 7'h37;
    localparam ADDR_SBCS         = 7'h38;
    localparam ADDR_SBADDRESS0   = 7'h39;
    localparam ADDR_SBADDRESS1   = 7'h3A;
    localparam ADDR_SBADDRESS2   = 7'h3B;
    localparam ADDR_SBDATA0      = 7'h3C;
    localparam ADDR_SBDATA1      = 7'h3D;
    localparam ADDR_SBDATA2      = 7'h3E;
    localparam ADDR_SBDATA3      = 7'h3F;
    localparam ADDR_HALTSUM0     = 7'h40;

    wire is_progbuf_addr = (i_reg_addr >= ADDR_PROGBUF_LO) && (i_reg_addr <= ADDR_PROGBUF_HI);

    /* ----------------------------------------------------------------- *
     * dmcontrol -- dmactive/haltreq are real, functional storage.
     * resumereq is intentionally NOT stored (spec allows write-only
     * semantics for it): a write with bit30 set generates a single-cycle
     * o_debug_resume_req pulse directly, combinationally, off the same
     * cycle's i_reg_wdata -- exactly matching core0.i_debug_resume_req's
     * own "one-cycle pulse" contract with no extra registering needed.
     * hartreset/ackhavereset/hasel/hartsello/hartselhi/ndmreset are
     * accepted and stored for readback but have no functional effect
     * this milestone (single-hart: hart selection is inherently a
     * no-op; hartreset/ndmreset/havereset-tracking are the same
     * "accepted but not implemented" scope decision this project has
     * already made for WFI and for MRET's hartreset-adjacent fields
     * elsewhere) -- dmactive does NOT yet gate these other fields'
     * storage (a deliberate, documented simplification: nothing this
     * milestone's own test needs that gating for).
     * ----------------------------------------------------------------- */
    logic [31:0] dmcontrol_q;
    wire dmcontrol_write_now = i_reg_we && (i_reg_addr == ADDR_DMCONTROL);

    always_ff @(posedge clk) begin
        if (rst) dmcontrol_q <= 32'b0;
        else if (dmcontrol_write_now)
            // bit 30 (resumereq) deliberately excluded from storage --
            // see the header comment above.
            dmcontrol_q <= {i_reg_wdata[31], 1'b0, i_reg_wdata[29:0]};
    end

    assign o_debug_halt_req   = dmcontrol_q[31];
    assign o_debug_resume_req = dmcontrol_write_now && i_reg_wdata[30];

    /* ----------------------------------------------------------------- *
     * dmstatus -- read-only, purely combinational. See the module
     * header's "NOTE ON SPEC FIDELITY" for which fields are real vs.
     * documented-reserved-0.
     * ----------------------------------------------------------------- */
    wire dmstatus_allhalted  = i_hart_halted;
    wire dmstatus_anyhalted  = i_hart_halted;
    wire dmstatus_allrunning = !i_hart_halted;
    wire dmstatus_anyrunning = !i_hart_halted;
    wire [31:0] dmstatus_real = {
        22'b0,                                   // [31:10] reserved this milestone
        dmstatus_allrunning, dmstatus_anyrunning, // [9:8]
        dmstatus_allhalted,  dmstatus_anyhalted,  // [7:6]
        1'b1,                                     // [5] authenticated
        1'b0,                                     // [4] authbusy
        4'd2                                      // [3:0] version = 2 (0.13/1.0)
    };

    /* ----------------------------------------------------------------- *
     * hartinfo -- read-only, fixed. dataaccess=1 (data0/data1 are
     * accessed only through this module's own DMI-visible registers,
     * never shadowed into the hart's own CSR space) and nscratch=2
     * (dscratch0/dscratch1, shipped in Milestone 3) are the only two
     * fields this milestone gives real meaning to.
     * ----------------------------------------------------------------- */
    localparam [31:0] HARTINFO_VAL = {8'b0, 4'd2, 3'b0, 1'b1, 4'b0, 12'b0};
    // [31:24] reserved, [23:20] nscratch=2, [19:17] reserved, [16] dataaccess=1,
    // [15:12] datasize=0 (unused, dataaccess=1), [11:0] datastart=0 (unused)

    /* ----------------------------------------------------------------- *
     * abstractcs -- datacount is fixed (2 32-bit words = one 64-bit
     * XLEN transfer via data0+data1); busy/cmderr are real.
     * ----------------------------------------------------------------- */
    logic [2:0] cmderr_q;
    logic       busy_q;
    wire [31:0] abstractcs_val = {19'b0, busy_q, 3'b0, cmderr_q, 2'b0, 4'd2};
    // [31:13] reserved, [12] busy, [11:9] reserved, [8:6] cmderr,
    // [5:4] reserved, [3:0] datacount=2

    /* ----------------------------------------------------------------- *
     * data0/data1 -- the 64-bit GPR/CSR transfer pair (data0 = low
     * 32 bits, data1 = high 32 bits). Declared here, ahead of the
     * command-execution section below that reads {data1_q, data0_q} as
     * a WRITE command's source data -- the always_ff that actually
     * DRIVES data0_q/data1_q (including the READ-command capture path,
     * which depends on cmd_do_gpr/cmd_do_csr below) is placed further
     * down, after those wires exist; only the storage declaration needs
     * to be this early.
     * ----------------------------------------------------------------- */
    logic [31:0] data0_q, data1_q;

    /* ----------------------------------------------------------------- *
     * command -- Access Register (cmdtype=0) execution. Decoded live off
     * i_reg_wdata the same cycle `command` is DMI-written (see the
     * module header for why this is correct and doesn't need command_q
     * itself in the execution path); command_q below exists purely for
     * DMI readback convenience (spec allows either).
     * ----------------------------------------------------------------- */
    logic [31:0] command_q;
    wire cmd_write_now = i_reg_we && (i_reg_addr == ADDR_COMMAND);

    wire [7:0]  cmd_cmdtype   = i_reg_wdata[31:24];
    wire [2:0]  cmd_aarsize   = i_reg_wdata[22:20];
    wire        cmd_postexec  = i_reg_wdata[18];
    wire        cmd_transfer  = i_reg_wdata[17];
    wire        cmd_write_reg = i_reg_wdata[16];
    wire [15:0] cmd_regno     = i_reg_wdata[15:0];

    // GPR range 0x1000-0x101F (x0-x31); CSR range 0x0000-0x0FFF.
    wire cmd_regno_is_gpr = (cmd_regno[15:5] == 11'h080);
    wire cmd_regno_is_csr = !cmd_regno_is_gpr && (cmd_regno[15:12] == 4'h0);

    /*
     * Only a full 64-bit (aarsize=3) transfer is accepted -- this core's
     * GPRs/CSRs are always 64-bit wide, and o_dm_gpr_wdata/o_dm_csr_wdata
     * unconditionally source the full {data1_q, data0_q} pair with no
     * narrowing logic anywhere downstream (register_file.sv/csr_file.sv
     * both perform a plain full-width write). Accepting aarsize=2 (32-bit)
     * as "supported" without ever honoring it would let a WRITE command
     * silently clobber a target register's upper 32 bits with whatever
     * stale value data1_q last held (e.g. the upper half of an unrelated
     * earlier READ) -- real data corruption, not a spec-fidelity nicety.
     * Rejecting it here (cmd_supported -> false -> cmderr=2, "not
     * supported") is the correct, spec-legal response instead.
     */
    wire cmd_aarsize_ok = (cmd_aarsize == 3'd3);
    wire cmd_regno_ok   = !cmd_transfer || cmd_regno_is_gpr || cmd_regno_is_csr;
    wire cmd_supported  = (cmd_cmdtype == 8'h00) && !cmd_postexec && cmd_aarsize_ok && cmd_regno_ok;

    // Legal: hart halted, DM not already mid-command, no sticky error
    // pending, and the requested command is one this milestone supports.
    wire cmd_legal = cmd_write_now && i_hart_halted && !busy_q
                   && (cmderr_q == 3'd0) && cmd_supported;

    wire cmd_do_gpr = cmd_legal && cmd_transfer && cmd_regno_is_gpr;
    wire cmd_do_csr = cmd_legal && cmd_transfer && cmd_regno_is_csr;

    /*
     * cmderr priority mirrors the spec's own "halt/resume" > "busy" >
     * "not supported" ordering, and only ever latches the FIRST error
     * after a clean (cmderr==0) state -- a second concurrent error
     * reason is never distinguished, matching the spec's own
     * "the DM does not attempt to determine whether more than one error
     * occurred" allowance. A write to abstractcs with a nonzero cmderr
     * field clears it (W1C, per spec) -- takes priority over a same-
     * cycle command write since they can't both be addressed to
     * abstractcs and command at once anyway (different i_reg_addr).
     */
    always_ff @(posedge clk) begin
        if (rst) begin
            cmderr_q <= 3'd0;
        end else if (i_reg_we && (i_reg_addr == ADDR_ABSTRACTCS) && (i_reg_wdata[8:6] != 3'd0)) begin
            cmderr_q <= 3'd0;
        end else if (cmd_write_now && (cmderr_q == 3'd0)) begin
            if (!i_hart_halted)        cmderr_q <= 3'd4;  // halt/resume
            else if (busy_q)           cmderr_q <= 3'd1;  // busy
            else if (!cmd_supported)   cmderr_q <= 3'd2;  // not supported
        end
    end

    always_ff @(posedge clk) begin
        if (rst) busy_q <= 1'b0;
        else     busy_q <= cmd_legal;
    end

    always_ff @(posedge clk) begin
        if (rst) command_q <= 32'b0;
        else if (cmd_write_now) command_q <= i_reg_wdata;
    end

    assign o_dm_gpr_we    = cmd_do_gpr && cmd_write_reg;
    assign o_dm_gpr_sel   = cmd_regno[4:0];
    assign o_dm_gpr_wdata = {data1_q, data0_q};

    assign o_dm_csr_we    = cmd_do_csr && cmd_write_reg;
    assign o_dm_csr_addr  = cmd_regno[11:0];
    assign o_dm_csr_wdata = {data1_q, data0_q};

    /* ----------------------------------------------------------------- *
     * abstractauto -- storage only, no functional effect this milestone
     * (real "auto-execute the last command on every data0/data1
     * DMI access" behavior is a nice-to-have this milestone's own gate
     * doesn't require -- the DMI backdoor testbench drives `command`
     * directly each time instead).
     * ----------------------------------------------------------------- */
    logic [31:0] abstractauto_q;
    always_ff @(posedge clk) begin
        if (rst) abstractauto_q <= 32'b0;
        else if (i_reg_we && (i_reg_addr == ADDR_ABSTRACTAUTO)) abstractauto_q <= i_reg_wdata;
    end

    /* ----------------------------------------------------------------- *
     * data0/data1's actual driving logic. A completed READ Access
     * Register command captures the target register's value here on the
     * same edge it executes; otherwise, a plain DMI write updates either
     * half directly (the normal path a debugger uses to stage a value
     * before issuing a WRITE command).
     * ----------------------------------------------------------------- */
    always_ff @(posedge clk) begin
        if (rst) begin
            data0_q <= 32'b0;
            data1_q <= 32'b0;
        end else if (cmd_do_gpr && !cmd_write_reg) begin
            {data1_q, data0_q} <= i_dm_gpr_rdata;
        end else if (cmd_do_csr && !cmd_write_reg) begin
            {data1_q, data0_q} <= i_dm_csr_rdata;
        end else begin
            if (i_reg_we && (i_reg_addr == ADDR_DATA0)) data0_q <= i_reg_wdata;
            if (i_reg_we && (i_reg_addr == ADDR_DATA1)) data1_q <= i_reg_wdata;
        end
    end

    /* ----------------------------------------------------------------- *
     * System Bus Access + Program Buffer -- storage-only stubs this
     * milestone (Milestone 8 and Milestone 7 give them real backing).
     * sbcs.sbaccess8/16/32/64/128 (bits [7:5,4] in the real spec layout)
     * are hardwired 0 within sbcs_val below regardless of what's
     * written -- a real debugger reads "no access width supported" and
     * correctly never attempts a System Bus Access against this DM, the
     * spec-clean way to say "not implemented" without needing a fake
     * per-transaction sberror flow.
     * ----------------------------------------------------------------- */
    logic [31:0] sbcs_q;
    logic [31:0] sbaddress0_q, sbaddress1_q, sbaddress2_q, sbaddress3_q;
    logic [31:0] sbdata0_q, sbdata1_q, sbdata2_q, sbdata3_q;
    logic [31:0] progbuf_q [0:15];

    localparam [31:0] SBCS_ACCESS_MASK = 32'hFFFF_FE0F;  // clears bits [8:4] (sbaccess128..sbaccess8)
    wire [31:0] sbcs_val = sbcs_q & SBCS_ACCESS_MASK;

    always_ff @(posedge clk) begin
        if (rst) begin
            sbcs_q       <= 32'h0000_0020;  // sbversion=1 (bits[31:29]=0, spec places
                                             // sbversion at [31:29]; kept 0 here since
                                             // this stub advertises no capability either
                                             // way -- see the header note on fields
                                             // best-effort-placed without a spec copy)
            sbaddress0_q <= 32'b0;
            sbaddress1_q <= 32'b0;
            sbaddress2_q <= 32'b0;
            sbaddress3_q <= 32'b0;
            sbdata0_q    <= 32'b0;
            sbdata1_q    <= 32'b0;
            sbdata2_q    <= 32'b0;
            sbdata3_q    <= 32'b0;
        end else if (i_reg_we) begin
            case (i_reg_addr)
                ADDR_SBCS:       sbcs_q       <= i_reg_wdata;
                ADDR_SBADDRESS0: sbaddress0_q <= i_reg_wdata;
                ADDR_SBADDRESS1: sbaddress1_q <= i_reg_wdata;
                ADDR_SBADDRESS2: sbaddress2_q <= i_reg_wdata;
                ADDR_SBADDRESS3: sbaddress3_q <= i_reg_wdata;
                ADDR_SBDATA0:    sbdata0_q    <= i_reg_wdata;
                ADDR_SBDATA1:    sbdata1_q    <= i_reg_wdata;
                ADDR_SBDATA2:    sbdata2_q    <= i_reg_wdata;
                ADDR_SBDATA3:    sbdata3_q    <= i_reg_wdata;
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 16; i++) progbuf_q[i] <= 32'b0;
        end else if (i_reg_we && is_progbuf_addr) begin
            progbuf_q[i_reg_addr[3:0]] <= i_reg_wdata;
        end
    end

    /* ----------------------------------------------------------------- *
     * haltsum0 -- bit n = 1 if hart n is halted. Single-hart: only bit 0
     * is meaningful.
     * ----------------------------------------------------------------- */
    wire [31:0] haltsum0_val = {31'b0, i_hart_halted};

    /* ----------------------------------------------------------------- *
     * Flat read-mux, matching this codebase's own established
     * csr_file.sv/clint.sv convention.
     * ----------------------------------------------------------------- */
    always_comb begin
        case (i_reg_addr)
            ADDR_DATA0:        o_reg_rdata = data0_q;
            ADDR_DATA1:        o_reg_rdata = data1_q;
            ADDR_DMCONTROL:    o_reg_rdata = dmcontrol_q;
            ADDR_DMSTATUS:     o_reg_rdata = dmstatus_real;
            ADDR_HARTINFO:     o_reg_rdata = HARTINFO_VAL;
            ADDR_ABSTRACTCS:   o_reg_rdata = abstractcs_val;
            ADDR_COMMAND:      o_reg_rdata = command_q;
            ADDR_ABSTRACTAUTO: o_reg_rdata = abstractauto_q;
            ADDR_SBCS:         o_reg_rdata = sbcs_val;
            ADDR_SBADDRESS0:   o_reg_rdata = sbaddress0_q;
            ADDR_SBADDRESS1:   o_reg_rdata = sbaddress1_q;
            ADDR_SBADDRESS2:   o_reg_rdata = sbaddress2_q;
            ADDR_SBADDRESS3:   o_reg_rdata = sbaddress3_q;
            ADDR_SBDATA0:      o_reg_rdata = sbdata0_q;
            ADDR_SBDATA1:      o_reg_rdata = sbdata1_q;
            ADDR_SBDATA2:      o_reg_rdata = sbdata2_q;
            ADDR_SBDATA3:      o_reg_rdata = sbdata3_q;
            ADDR_HALTSUM0:     o_reg_rdata = haltsum0_val;
            default:           o_reg_rdata = is_progbuf_addr ? progbuf_q[i_reg_addr[3:0]] : 32'b0;
        endcase
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
