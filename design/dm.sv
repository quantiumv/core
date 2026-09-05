// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: dm
 *
 * Debug Module register file (Milestone 5 of the EBREAK/JTAG staged
 * plan -- see [[debug-halt-fsm-milestone]] for Milestone 4, which added
 * the halt/resume/step FSM this module now drives; [[jtag-tap-dmi-milestone]]
 * for Milestone 6, the real JTAG/DMI transport in front of this module's
 * own plain register interface). Implements the subset of the RISC-V
 * Debug Specification (0.13.2/1.0) register set needed for a debugger to
 * halt/resume/step the hart, read/write a GPR or CSR while it's halted
 * (an "Access Register" abstract command, cmdtype=0), and -- Milestone 7
 * -- run a small Program Buffer sequence against live GPR/CSR state
 * (that same abstract command's postexec bit, see the Program Buffer
 * section below and design/core.sv's own matching section for the full
 * execution design). System Bus Access and Quick Access commands still
 * get register STORAGE only (so their own shape is proven once) but no
 * functional backing until Milestone 8.
 *
 * NOTE ON SPEC FIDELITY: this repo has no local copy of the RISC-V
 * Debug Specification, but every register's bit layout below (dmcontrol,
 * dmstatus, hartinfo, abstractcs, sbcs's access-width mask, command's
 * Access Register encoding) has been cross-checked field-by-field
 * against riscv/riscv-debug-spec's own xml/dm_registers.xml -- the
 * machine-readable source the spec's own published tables are generated
 * from (Milestone 5's own spec-fidelity fix pass, 2026-09-05; see the
 * plan file for the full derivation and what it found: two real
 * position bugs, both now fixed -- abstractcs.cmderr had drifted to
 * [8:6] instead of the real [10:8], and sbcs's access-width mask was
 * clearing the wrong 5 bits entirely). Every dmstatus field now has a
 * real, well-justified value, not a placeholder -- see the dmstatus_real
 * assign's own comment for the reasoning behind each one.
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
    input  logic [63:0] i_dm_csr_rdata,

    /*
     * Program Buffer execution (Milestone 7's own new core0 ports).
     * o_progbuf_start is a one-cycle pulse (fires the same cycle a
     * postexec command is accepted); i_progbuf_pc is which progbuf0-15
     * slot core0 currently wants (a plain array index, not a byte
     * address), read back combinationally as o_progbuf_data (this
     * module's own progbuf_q storage has no read latency, mirroring the
     * Access Register GPR/CSR reads already above); i_progbuf_done/
     * i_progbuf_abort are one-cycle pulses reporting how the run ended.
     */
    output logic        o_progbuf_start,
    input  logic [3:0]  i_progbuf_pc,
    output logic [31:0] o_progbuf_data,
    input  logic        i_progbuf_done,
    input  logic        i_progbuf_abort
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
     * milestone's own test needs that gating for). Field positions
     * (haltreq@31/resumereq@30/hartsello@[25:16]/hartselhi@[15:6]/
     * dmactive@0) are cross-checked against riscv-debug-spec's own
     * xml/dm_registers.xml and already correct. That same XML lists a
     * few spec-1.0-only fields this comment doesn't individually name
     * (ackunavail, setkeepalive/clrkeepalive) -- they're already safely
     * covered by the raw wdata[29:0] passthrough below, same "accepted,
     * no special handling" treatment as hartreset/ndmreset.
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
     * dmstatus -- read-only, purely combinational. Field positions below
     * are cross-checked against riscv/riscv-debug-spec's own
     * xml/dm_registers.xml (the machine-readable source the spec's
     * published tables are generated from) -- not a best-effort guess
     * anymore (see the Milestone 5 spec-fidelity fix pass note in the
     * plan file for how this was verified). Every field now has a real,
     * well-justified value: allnonexistent/anynonexistent/allunavail/
     * anyunavail read 0 because this is a single-hart system where hart
     * 0 always exists and is always available; allhavereset/anyhavereset
     * read 0 because no reset-tracking is implemented (consistent with
     * dmcontrol.hartreset/ndmreset already being accepted-but-inert);
     * impebreak reads 0 because this Program Buffer implementation
     * (Milestone 7) never auto-appends an implicit ebreak after a run --
     * the debugger's own trailing EBREAK is required, so a debugger must
     * not assume one is implied; hasresethaltreq/confstrptrvalid read 0
     * because neither is implemented. allresumeack/anyresumeack are a documented
     * approximation (dmstatus_resumeack, below) -- this core's resume is
     * effectively synchronous with no separate ack-tracking state worth
     * modeling this milestone, so they just mirror "currently running".
     * ----------------------------------------------------------------- */
    wire dmstatus_allhalted  = i_hart_halted;
    wire dmstatus_anyhalted  = i_hart_halted;
    wire dmstatus_allrunning = !i_hart_halted;
    wire dmstatus_anyrunning = !i_hart_halted;
    wire dmstatus_resumeack  = !i_hart_halted;
    wire [31:0] dmstatus_real = {
        7'b0,                                     // [31:25] reserved
        1'b0,                                     // [24] ndmresetpending
        1'b0,                                     // [23] stickyunavail
        1'b0,                                     // [22] impebreak
        2'b0,                                      // [21:20] reserved
        1'b0,                                     // [19] allhavereset
        1'b0,                                     // [18] anyhavereset
        dmstatus_resumeack, dmstatus_resumeack,   // [17:16] allresumeack, anyresumeack
        1'b0,                                     // [15] allnonexistent
        1'b0,                                     // [14] anynonexistent
        1'b0,                                     // [13] allunavail
        1'b0,                                     // [12] anyunavail
        dmstatus_allrunning, dmstatus_anyrunning, // [11:10] allrunning, anyrunning
        dmstatus_allhalted,  dmstatus_anyhalted,  // [9:8] allhalted, anyhalted
        1'b1,                                     // [7] authenticated
        1'b0,                                     // [6] authbusy
        1'b0,                                     // [5] hasresethaltreq
        1'b0,                                     // [4] confstrptrvalid
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
    // [15:12] datasize=0 (unused, dataaccess=1), [11:0] dataaddr=0 (unused) --
    // field positions confirmed against riscv-debug-spec's own dm_registers.xml,
    // identical to this file's own layout, no change needed here beyond this
    // comment's field name (spec calls it dataaddr, not datastart).

    /* ----------------------------------------------------------------- *
     * abstractcs -- datacount is fixed (2 32-bit words = one 64-bit
     * XLEN transfer via data0+data1); busy/cmderr are real. Field
     * positions cross-checked against riscv-debug-spec's own
     * xml/dm_registers.xml (see the Milestone 5 spec-fidelity fix pass
     * note in the plan file) -- cmderr genuinely lives at [10:8], not
     * [8:6] as an earlier pass here had it. progbufsize ([28:24]) and
     * relaxedpriv ([11], a spec-1.0-only field for non-Debug-Mode
     * CSR/bus access this core doesn't support) are both absorbed into
     * the reserved-0 catch-all below -- reporting 0 for both is the
     * spec-correct way to tell a debugger neither capability exists yet
     * (Program Buffer/relaxed-priv access are later milestones).
     * ----------------------------------------------------------------- */
    logic [2:0] cmderr_q;
    logic       busy_q;
    /*
     * progbuf_q/progbuf_running_q: forward-declared here (Icarus needs
     * declaration-before-use, unlike a plain continuous assign's usual
     * order-independence) since busy_q's own always_ff below reads
     * progbuf_running_q, and the Program Buffer section further down
     * reads progbuf_q -- both well before either's own real write-logic
     * naturally belongs (progbuf_running_q's own always_ff sits with
     * the rest of the Program Buffer section; progbuf_q's own storage
     * write-logic sits with the other DMI-addressed registers, in the
     * System Bus Access section further down -- same "declare early,
     * drive/write late" split this file already uses for data0_q/
     * data1_q above).
     */
    logic progbuf_running_q;
    logic [31:0] progbuf_q [0:15];
    // progbufsize=16 (Milestone 7 -- real now, not a placeholder: this
    // module genuinely has 16 progbuf words and can genuinely run them).
    wire [31:0] abstractcs_val = {3'b0, 5'd16, 11'b0, busy_q, 1'b0, cmderr_q, 4'b0, 4'd2};
    // [31:29] reserved, [28:24] progbufsize=16, [23:13] reserved, [12] busy,
    // [11] relaxedpriv=0, [10:8] cmderr, [7:4] reserved, [3:0] datacount=2

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
     * supported") is the correct, spec-legal response instead. aarsize
     * is only meaningful when a transfer is actually happening -- a
     * postexec-only command (transfer=0, just run the Program Buffer)
     * shouldn't be rejected over an aarsize field the debugger had no
     * reason to set meaningfully.
     */
    wire cmd_aarsize_ok = (cmd_aarsize == 3'd3);
    wire cmd_regno_ok   = !cmd_transfer || cmd_regno_is_gpr || cmd_regno_is_csr;
    // postexec (Milestone 7) is now accepted for any Access Register
    // command -- see the Program Buffer section below for its own
    // execution logic.
    wire cmd_supported  = (cmd_cmdtype == 8'h00) && (!cmd_transfer || cmd_aarsize_ok) && cmd_regno_ok;

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
     * field clears it (W1C, per spec) -- this used to unconditionally
     * take top priority, on the reasoning that it "can't collide with a
     * same-cycle command write since they can't both be addressed to
     * abstractcs and command at once" -- true for cmd_write_now (same
     * i_reg_addr/i_reg_we port), but FALSE for i_progbuf_abort (Milestone
     * 7 review fix): that's an independent, core0-originated pulse, not
     * gated by i_reg_addr/i_reg_we at all, so a debugger W1C-clearing
     * some earlier, unrelated sticky error could land on the exact same
     * cycle a running Program Buffer sequence aborts. i_progbuf_abort is
     * therefore checked FIRST now -- a genuine, fresh hardware-detected
     * exception must never be silently swallowed by a same-cycle software
     * clear of a stale, unrelated error. This doesn't change the ordinary
     * (non-racing) case at all: i_progbuf_abort is 0 on every cycle a W1C
     * write isn't racing it, so the W1C branch still fires exactly as
     * before.
     */
    always_ff @(posedge clk) begin
        if (rst) begin
            cmderr_q <= 3'd0;
        end else if (i_progbuf_abort && (cmderr_q == 3'd0)) begin
            cmderr_q <= 3'd3;  // exception (Milestone 7) -- see the Program Buffer section below
        end else if (i_reg_we && (i_reg_addr == ADDR_ABSTRACTCS) && (i_reg_wdata[10:8] != 3'd0)) begin
            cmderr_q <= 3'd0;
        end else if (cmd_write_now && (cmderr_q == 3'd0)) begin
            if (!i_hart_halted)        cmderr_q <= 3'd4;  // halt/resume
            else if (busy_q)           cmderr_q <= 3'd1;  // busy
            else if (!cmd_supported)   cmderr_q <= 3'd2;  // not supported
        end
    end

    /*
     * busy_q (Milestone 7 update): a plain 1-cycle-delayed echo of
     * cmd_legal for an ordinary Access Register transfer (unchanged
     * from Milestone 5 -- busy for exactly the cycle after acceptance,
     * then clears), but genuinely MULTI-cycle for a postexec command:
     * it stays set for as long as progbuf_running_q does, only clearing
     * once core0 reports i_progbuf_done/i_progbuf_abort. The three
     * branches are mutually exclusive by construction: i_progbuf_done/
     * i_progbuf_abort can only fire while progbuf_running_q is already
     * 1, and cmd_legal cannot be true while busy_q (hence
     * progbuf_running_q, transitively) is still 1 -- so there's no
     * cycle where more than one of these branches is actually relevant.
     */
    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q <= 1'b0;
        end else if (i_progbuf_done || i_progbuf_abort) begin
            busy_q <= 1'b0;
        end else if (cmd_legal) begin
            busy_q <= 1'b1;
        end else if (!progbuf_running_q) begin
            busy_q <= 1'b0;
        end
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
     * Program Buffer execution (Milestone 7). o_progbuf_start fires the
     * same cycle a postexec command is accepted -- independent of
     * cmd_do_gpr/cmd_do_csr above (a command can combine a register
     * transfer with postexec, or use postexec alone with transfer=0;
     * both compose correctly since they're separate output pins core0
     * consumes independently). progbuf_running_q tracks the run for as
     * long as core0 hasn't yet reported i_progbuf_done/i_progbuf_abort
     * -- this is the one command shape in this module that doesn't
     * resolve in a single clock edge (see the module header's own
     * contrast between Access Register transfers and this).
     * ----------------------------------------------------------------- */
    assign o_progbuf_start = cmd_legal && cmd_postexec;
    assign o_progbuf_data  = progbuf_q[i_progbuf_pc];

    always_ff @(posedge clk) begin
        if (rst) begin
            progbuf_running_q <= 1'b0;
        end else if (cmd_legal && cmd_postexec) begin
            progbuf_running_q <= 1'b1;
        end else if (i_progbuf_done || i_progbuf_abort) begin
            progbuf_running_q <= 1'b0;
        end
    end

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
     * System Bus Access -- storage-only stub (Milestone 8 gives it real
     * backing). sbcs.sbaccess8/16/32/64/128 (bits [4:0] -- cross-checked
     * against riscv-debug-spec's own xml/dm_registers.xml; an earlier
     * pass here had this at bits [8:4], which meant the mask below
     * didn't actually clear the real capability bits at all) are
     * hardwired 0 within sbcs_val below regardless of what's written --
     * a real debugger reads "no access width supported" and correctly
     * never attempts a System Bus Access against this DM, the spec-clean
     * way to say "not implemented" without needing a fake per-
     * transaction sberror flow.
     *
     * progbuf_q -- the Program Buffer's own storage -- is declared here
     * too (same array, same address decode as always), but is no longer
     * a stub: Milestone 7's own Program Buffer section above reads it
     * combinationally via o_progbuf_data, and o_progbuf_start/
     * progbuf_running_q (also above) drive real execution through
     * core0.
     * ----------------------------------------------------------------- */
    logic [31:0] sbcs_q;
    logic [31:0] sbaddress0_q, sbaddress1_q, sbaddress2_q, sbaddress3_q;
    logic [31:0] sbdata0_q, sbdata1_q, sbdata2_q, sbdata3_q;
    // progbuf_q itself is forward-declared earlier (see that comment) --
    // only its write-logic (the always_ff below) lives here.

    localparam [31:0] SBCS_ACCESS_MASK = 32'hFFFF_FFE0;  // clears bits [4:0] (sbaccess8..sbaccess128)
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
