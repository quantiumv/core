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
 * (an "Access Register" abstract command, cmdtype=0), run a small
 * Program Buffer sequence against live GPR/CSR state (Milestone 7, that
 * same abstract command's postexec bit -- see the Program Buffer section
 * below and design/core.sv's own matching section for the full execution
 * design), and -- Milestone 8 -- read/write real memory-mapped state
 * directly over a second Wishbone master port (System Bus Access, the
 * sbcs/sbaddress0/sbdata0/sbdata1 registers -- see that section below).
 * Quick Access commands still get register STORAGE only (so their own
 * shape is proven once) but no functional backing -- deferred
 * indefinitely, see the plan file's own scope boundary. Milestone 10a
 * adds a real DMI read-strobe (i_reg_re, sourced from design/dm_dmi.sv's
 * own transport FSM) and makes sbcs.sbreadondata and
 * abstractauto.autoexecdata functionally real -- both were previously
 * storage-only, discovered as genuine gaps while planning Milestone 10's
 * OpenOCD integration test (a multi-word memory read is the overwhelmingly
 * common real-world case).
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
 * i_reg_re (Milestone 10a): a genuine "a read just happened" strobe,
 * ANSI-defaulted 1'b0 since every reader before this milestone (this
 * module's own read-mux, every existing DMI-backdoor testbench) never
 * needed one -- only soc.sv drives it for real, via design/dm_dmi.sv's
 * own free derivation off its existing delay_q FSM (see that file's
 * header). Consumed below by sbcs.sbreadondata and
 * abstractauto.autoexecdata, the two register fields whose real
 * semantics depend on a READ (not just a stable address) having
 * genuinely occurred.
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
    input  logic        i_reg_re = 1'b0,
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
    input  logic        i_progbuf_abort,

    /*
     * System Bus Access (Milestone 8 of the EBREAK/JTAG staged plan --
     * see [[dm-progbuf-milestone]] for Milestone 7). A genuine second
     * Wishbone MASTER port -- unlike every other port group above, which
     * reaches into core0's own internals via dedicated side-channel
     * ports, this one goes straight onto the shared memory fabric
     * through design/wb_arbiter2.sv (soc.sv wires it there, arbitrated
     * against core0's own ordinary master port, m1/higher priority --
     * see that module's own header for the policy and why). Lets a
     * debugger read/write real memory-mapped state (RAM, UART, CLINT)
     * directly, independent of whether the hart is halted at all -- the
     * one Access Register capability (GPR/CSR read/write) fundamentally
     * cannot provide, since those require the hart's own decode/execute
     * path and hence a real halt. Ordinary registered Wishbone classic
     * timing: cyc_o/stb_o are held until ack_i or err_i arrives, exactly
     * matching every other master in this design (core.sv's own
     * wb_master_drive).
     */
    output logic [31:0] o_sba_addr,
    output logic [63:0] o_sba_dat,
    input  logic [63:0] i_sba_dat,
    output logic [7:0]  o_sba_sel,
    output logic        o_sba_we,
    output logic        o_sba_cyc,
    output logic        o_sba_stb,
    input  logic        i_sba_ack,
    input  logic        i_sba_err
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
     * because neither is implemented.
     *
     * allresumeack/anyresumeack (Milestone 10b fix -- was a documented
     * "= !i_hart_halted" approximation until a real OpenOCD integration
     * test discovered it breaks the single-step operation for real):
     * OpenOCD's own `step` implementation issues resumereq, then POLLS
     * dmstatus waiting for allresumeack==1 BEFORE it will even check for
     * the step's own following auto-re-halt. A single-step's whole
     * resume-execute-one-instruction-rehalt cycle completes in a
     * handful of clk edges -- reliably FASTER than one DMI round trip
     * through design/dm_dmi.sv's own CDC (~6+ clk edges) plus the real
     * JTAG bit-banging on top of that -- so a live "!i_hart_halted"
     * reads "still halted" for the entire step, every single time a
     * debugger polls it: the transient "running" window is real, but no
     * external poll can ever land inside it. Real spec text: "This bit
     * is 0 after resumereq is written until the hart resumes, at which
     * point it goes to 1 and remains set" -- i.e. it must survive an
     * arbitrarily fast subsequent re-halt, clearing only on the NEXT
     * debugger-initiated haltreq/resumereq request, not on the hart
     * re-halting per se (which, for single-step, is the step's own
     * intended, immediate outcome -- not something that should erase
     * the very ack the debugger is still waiting to observe).
     * ----------------------------------------------------------------- */
    wire dmstatus_allhalted  = i_hart_halted;
    wire dmstatus_anyhalted  = i_hart_halted;
    wire dmstatus_allrunning = !i_hart_halted;
    wire dmstatus_anyrunning = !i_hart_halted;

    logic resumeack_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            resumeack_q <= 1'b0;
        end else if (o_debug_resume_req) begin
            resumeack_q <= 1'b1;
        end else if (dmcontrol_write_now && (i_reg_wdata[31] || i_reg_wdata[30])) begin
            // A fresh haltreq OR resumereq write clears the PREVIOUS
            // resume's own stale ack. Mutually exclusive with the
            // o_debug_resume_req branch above by construction (same
            // dmcontrol_write_now && wdata[30] condition would hit that
            // branch first), so a fresh resumereq itself still correctly
            // sets resumeack_q<=1, not this clear.
            resumeack_q <= 1'b0;
        end
    end
    wire dmstatus_resumeack = resumeack_q;
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

    /*
     * abstractauto.autoexecdata (Milestone 10a): a data0/data1 access
     * (read OR write) with the matching abstractauto bit set re-issues
     * the LAST command (command_q), not a fresh one. cmd_auto_retrigger_q
     * is forward-declared here (real driving always_ff lives in the
     * abstractauto_q section further down, once abstractauto_q/
     * data_access_now exist -- same "declare early, drive later" idiom
     * this file already uses for progbuf_q) since cmd_trigger_now's own
     * mux, right below, needs it before that point. It's a one-cycle-
     * deferred pulse (not combinational off the triggering access) so
     * that data0_q/data1_q have already latched a just-written value
     * before the retriggered transfer reads them -- see its own always_ff
     * for the full reasoning. cmd_write_now and cmd_auto_retrigger_q are
     * mutually exclusive by construction (one needs i_reg_addr==
     * ADDR_COMMAND this cycle, the other needs a data0/data1 access one
     * cycle ago), so cmd_effective_word's mux has no real priority
     * hazard. Every existing cmd_* decode below (previously sourced
     * directly off i_reg_wdata) now sources off cmd_effective_word
     * instead, transparently covering both triggers with no other
     * change needed at any downstream consumption site.
     */
    logic cmd_auto_retrigger_q;
    wire cmd_trigger_now = cmd_write_now || cmd_auto_retrigger_q;
    // Bits [23] and [19] (reserved, between cmdtype/aarsize and
    // aarsize/postexec) are genuinely never consumed below -- true of
    // the ORIGINAL i_reg_wdata-sourced decode too (no single 32-bit wire
    // existed there to trigger the warning), not a regression this
    // refactor introduced. Same "genuinely partial command/CSR bit
    // usage" precedent as dcsr_w/tdata1_0_w elsewhere in this project.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] cmd_effective_word = cmd_write_now ? i_reg_wdata : command_q;
    /* verilator lint_on UNUSEDSIGNAL */

    wire [7:0]  cmd_cmdtype   = cmd_effective_word[31:24];
    wire [2:0]  cmd_aarsize   = cmd_effective_word[22:20];
    wire        cmd_postexec  = cmd_effective_word[18];
    wire        cmd_transfer  = cmd_effective_word[17];
    wire        cmd_write_reg = cmd_effective_word[16];
    wire [15:0] cmd_regno     = cmd_effective_word[15:0];

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
    // cmd_trigger_now (not bare cmd_write_now) so an abstractauto
    // retrigger (Milestone 10a) is accepted/executed through exactly
    // the same legality gate an ordinary command write already is.
    wire cmd_legal = cmd_trigger_now && i_hart_halted && !busy_q
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
     *
     * Milestone 10a note: cmd_trigger_now's error check is ALSO checked
     * ahead of the W1C-clear branch now, for the identical reason --
     * cmd_write_now alone could never coincide with a same-cycle
     * ADDR_ABSTRACTCS write (same i_reg_addr/i_reg_we port, only one
     * address at a time), so the original ordering was safe by
     * construction. cmd_auto_retrigger_q breaks that: it's an
     * independent, registered pulse (not gated by this cycle's
     * i_reg_addr at all, same shape as i_progbuf_abort), so a debugger's
     * W1C-clear of some earlier, unrelated sticky error CAN now land on
     * the exact same cycle an autoexecdata retrigger detects a fresh
     * busy/not-supported condition. Reordering closes that race the same
     * way it was already closed for i_progbuf_abort; it's a no-op for
     * the ordinary cmd_write_now sub-case (still structurally exclusive
     * from a same-cycle W1C write, so its own behavior is unchanged).
     */
    always_ff @(posedge clk) begin
        if (rst) begin
            cmderr_q <= 3'd0;
        end else if (i_progbuf_abort && (cmderr_q == 3'd0)) begin
            cmderr_q <= 3'd3;  // exception (Milestone 7) -- see the Program Buffer section below
        end else if (cmd_trigger_now && (cmderr_q == 3'd0)
                     && (!i_hart_halted || busy_q || !cmd_supported)) begin
            if (!i_hart_halted)        cmderr_q <= 3'd4;  // halt/resume
            else if (busy_q)           cmderr_q <= 3'd1;  // busy
            else if (!cmd_supported)   cmderr_q <= 3'd2;  // not supported
        end else if (i_reg_we && (i_reg_addr == ADDR_ABSTRACTCS) && (i_reg_wdata[10:8] != 3'd0)) begin
            cmderr_q <= 3'd0;
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
     * abstractauto.autoexecdata (Milestone 10a): bits [1:0] are real --
     * a data0/data1 access (read OR write) with the matching bit set
     * re-issues the last command (command_q) via cmd_auto_retrigger_q,
     * whose own consumption is entirely in the cmd_effective_word/
     * cmd_trigger_now machinery above (declared there since it's needed
     * before this point textually; driven here, once abstractauto_q and
     * i_reg_re both exist). Bits [11:2] (data2-11) stay storage-only --
     * spec-legal, since this core only ever transfers via data0/data1.
     *
     * cmd_auto_retrigger_q is deliberately ONE CYCLE DEFERRED from the
     * triggering access, not combinational: for a WRITE-autoexec loop
     * (debugger staging data0/data1 to push values IN), data0_q/data1_q
     * only latch the just-written value on THIS edge (see the data0_q/
     * data1_q always_ff above) -- a combinational same-cycle retrigger
     * would read the OLD, pre-write value via {data1_q, data0_q}. A
     * READ-autoexec loop (pulling values OUT) has no equivalent hazard
     * (o_reg_rdata for the read itself is already combinational off the
     * PRE-retrigger data0_q/data1_q, unaffected by what this same edge's
     * retrigger does) -- but using the same one-cycle-deferred shape for
     * both keeps this a single, uniform mechanism rather than two
     * differently-timed ones. Same "defer by one cycle so dependent
     * state has settled" pattern design/core.sv's own interrupt-taking
     * milestone already established (commit_now_q/interrupt_taken).
     * ----------------------------------------------------------------- */
    logic [31:0] abstractauto_q;
    always_ff @(posedge clk) begin
        if (rst) abstractauto_q <= 32'b0;
        else if (i_reg_we && (i_reg_addr == ADDR_ABSTRACTAUTO)) abstractauto_q <= i_reg_wdata;
    end

    wire data_access_now = (i_reg_we || i_reg_re)
                         && ((i_reg_addr == ADDR_DATA0) || (i_reg_addr == ADDR_DATA1));
    wire autoexec_bit    = (i_reg_addr == ADDR_DATA0) ? abstractauto_q[0] : abstractauto_q[1];

    always_ff @(posedge clk) begin
        if (rst) cmd_auto_retrigger_q <= 1'b0;
        else     cmd_auto_retrigger_q <= data_access_now && autoexec_bit;
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
     * System Bus Access (Milestone 8) -- a real second Wishbone master,
     * driven off sbcs/sbaddress0/sbdata0/sbdata1. sbaddress1-3/sbdata2-3
     * stay storage-only stubs (see their own declarations further down):
     * this core's WB address bus is 32 bits (sbasize=32 below, fixed and
     * real, not a placeholder), so sbaddress1 (bits 63:32 of a wider
     * address) is spec-optional and never needed; sbdata2-3 are likewise
     * spec-optional above 64-bit accesses, which this core's 64-bit-wide
     * bus can't do anyway (sbaccess128 is hardwired 0 below).
     *
     * Field layout cross-checked against TWO independent sources (not
     * just riscv-debug-spec's own xml/dm_registers.xml, given how much
     * weight this milestone puts on getting sbcs right on the first
     * try): the spec XML itself and pulp-platform/riscv-dbg's own
     * sbcs_t packed struct (a real, widely-deployed implementation) --
     * both agree exactly on every field's position and width:
     *   [31:29] sbversion=1 (spec 1.0)   [22]    sbbusyerror (W1C)
     *   [21]    sbbusy                    [20]    sbreadonaddr
     *   [19:17] sbaccess                  [16]    sbautoincrement
     *   [15]    sbreadondata              [14:12] sberror (W1C)
     *   [11:5]  sbasize=32                [4:0]   sbaccess128..8
     *
     * Scope decisions, both deliberate and both documented rather than
     * silently absent:
     *  - sbaccess supports 8/16/32/64-bit (0-3); 128-bit (4) and above
     *    are rejected with sberror=4 ("not supported") -- this core's
     *    Wishbone bus is 64 bits wide, so 128-bit has no natural path,
     *    mirroring the Access Register command's own established
     *    "aarsize=3 (64-bit) only" precedent (see cmd_aarsize_ok above).
     *  - sbreadondata (auto-trigger a new read when sbdata0 is READ, per
     *    spec) is REAL as of Milestone 10a: sba_data_read_now (below)
     *    is gated on the genuine i_reg_re read-strobe design/dm_dmi.sv
     *    now derives for free from its own existing transport FSM (see
     *    that file's header) and threads through design/jtag_tap.sv/
     *    soc.sv/this module's own new i_reg_re input -- a debugger can
     *    now read a multi-word memory range via one sbaddress0 write
     *    followed by N plain sbdata0 reads, with no explicit re-trigger
     *    between them. sbdata1's own spec text ("accesses [including
     *    reads] while busy set sbbusyerror") still only detects
     *    WRITE-while-busy (sba_other_write_while_busy, below) -- a
     *    genuine read-while-busy collision would need sbdata1 gated the
     *    same way sba_data_read_now gates sbdata0, which nothing in this
     *    milestone's own gate (a correctly-sequenced debugger never
     *    reads sbdata1 while sba_busy_q, since it's waiting on the SAME
     *    busy flag to clear first) requires -- left as the one remaining
     *    narrower gap, same class as the SBA module's other documented
     *    "correctly-behaved debugger never hits this path" simplifications.
     *  - Misaligned accesses (sbaddress0 not naturally aligned to the
     *    current sbaccess width) are rejected instantly with sberror=3,
     *    never attempted on the bus -- a real, cheap correctness check
     *    (a misaligned access has no well-defined single-transaction
     *    byte-lane encoding on this bus), not scope creep.
     * ----------------------------------------------------------------- */
    logic        sbbusyerror_q;      // [22], W1C
    logic        sbreadonaddr_q;     // [20]
    logic [2:0]  sbaccess_q;         // [19:17]
    logic        sbautoincrement_q;  // [16]
    logic        sbreadondata_q;     // [15] -- real as of Milestone 10a (see above)
    logic [2:0]  sberror_q;          // [14:12], W1C
    logic [31:0] sbaddress0_q, sbaddress1_q, sbaddress2_q, sbaddress3_q;
    logic [31:0] sbdata0_q, sbdata1_q, sbdata2_q, sbdata3_q;
    // progbuf_q itself is forward-declared earlier (see that comment) --
    // only its write-logic (the always_ff below) lives here.

    logic        sba_busy_q;
    logic        sba_we_q;  // latched direction of the in-flight bus access

    localparam [6:0] SBASIZE = 7'd32;  // this core's real WB address width -- see the section header
    wire [31:0] sbcs_val = {
        3'd1,              // [31:29] sbversion = 1 (spec v1.0)
        6'b0,              // [28:23] reserved
        sbbusyerror_q,     // [22]
        sba_busy_q,        // [21] sbbusy
        sbreadonaddr_q,    // [20]
        sbaccess_q,        // [19:17]
        sbautoincrement_q, // [16]
        sbreadondata_q,    // [15]
        sberror_q,         // [14:12]
        SBASIZE,           // [11:5]
        1'b0,              // [4] sbaccess128 -- not supported, see above
        1'b1,              // [3] sbaccess64
        1'b1,              // [2] sbaccess32
        1'b1,              // [1] sbaccess16
        1'b1               // [0] sbaccess8
    };

    /*
     * Trigger detection. sba_effective_addr is the address a NEW
     * operation would actually use: for an sbaddress0-write-triggered
     * read, that's the INCOMING i_reg_wdata (about to become
     * sbaddress0_q's new value on this very edge, in the always_ff
     * below) -- using the stale, about-to-be-overwritten sbaddress0_q
     * here would validate the WRONG address. For an sbdata0-triggered
     * write OR a sbreadondata-triggered read (Milestone 10a), sbaddress0_q
     * is unchanged by either, so the current, stored value is exactly
     * right -- a read of sbdata0 never itself changes sbaddress0_q.
     */
    wire sba_addr_write_now = i_reg_we && (i_reg_addr == ADDR_SBADDRESS0);
    wire sba_data_write_now = i_reg_we && (i_reg_addr == ADDR_SBDATA0);
    wire sba_data_read_now  = i_reg_re && (i_reg_addr == ADDR_SBDATA0);  // Milestone 10a
    wire sba_new_op_requested = (sba_addr_write_now && sbreadonaddr_q)
                               || sba_data_write_now
                               || (sba_data_read_now && sbreadondata_q);  // Milestone 10a

    wire sba_access_ok = (sbaccess_q <= 3'd3);
    wire [2:0] sba_align_mask = (sbaccess_q == 3'd0) ? 3'b000 :
                                 (sbaccess_q == 3'd1) ? 3'b001 :
                                 (sbaccess_q == 3'd2) ? 3'b011 : 3'b111;
    // Only the low 3 bits of whichever address is about to become
    // effective are ever needed (the alignment check below never looks
    // higher) -- narrowed to exactly that width rather than declaring a
    // full 32-bit wire and only reading a slice of it.
    wire [2:0] sba_effective_addr_low3 = sba_addr_write_now ? i_reg_wdata[2:0] : sbaddress0_q[2:0];
    // Guarded by sba_access_ok so an unsupported width is reported as
    // exactly that (sberror=4) rather than ALSO, confusingly, as a
    // misalignment against a bogus mask for a width this DM doesn't
    // even support.
    wire sba_trigger_misaligned = sba_access_ok && (|(sba_effective_addr_low3 & sba_align_mask));

    wire sba_new_op_blocked_by_error = sbbusyerror_q || (sberror_q != 3'd0);
    wire sba_new_op_would_be_invalid = !sba_access_ok || sba_trigger_misaligned;

    wire sba_reject_as_busy_collision = sba_new_op_requested && sba_busy_q;
    wire sba_reject_as_invalid = sba_new_op_requested && !sba_busy_q
                                && !sba_new_op_blocked_by_error && sba_new_op_would_be_invalid;
    wire sba_start_real_op = sba_new_op_requested && !sba_busy_q
                            && !sba_new_op_blocked_by_error && !sba_new_op_would_be_invalid;

    // A write to sbcs or sbdata1 while an access is already in flight is
    // ALSO a busy collision (per spec: "if the bus manager is busy then
    // accesses set sbbusyerror" -- sbdata1's own wording; extended here
    // to sbcs writes too for the same reason, see the module header's
    // "why not just do it right" precedent this project already follows
    // elsewhere). sbaddress0 needs the same treatment specifically for
    // the sbreadonaddr_q==0 case: sba_reject_as_busy_collision already
    // covers an sbaddress0 write while busy WHEN sbreadonaddr_q==1 (that
    // write is itself a sba_new_op_requested trigger), but when
    // sbreadonaddr_q==0 the write is a plain address-staging write --
    // sba_new_op_requested never sees it at all, so without this term a
    // busy collision on that path went completely unflagged.
    wire sba_other_write_while_busy = sba_busy_q && i_reg_we
                                     && ((i_reg_addr == ADDR_SBCS) || (i_reg_addr == ADDR_SBDATA1)
                                         || (i_reg_addr == ADDR_SBADDRESS0 && !sbreadonaddr_q));

    // Hardware-set conditions are checked BEFORE the software W1C-clear
    // write, mirroring cmderr_q's own precedent above: a same-cycle race
    // between a new hardware-detected error and a debugger's clear-write
    // must let the new error win, not get silently swallowed by the
    // clear that was aimed at the OLD (about-to-be-superseded) value.
    always_ff @(posedge clk) begin
        if (rst) begin
            sbbusyerror_q <= 1'b0;
        end else if (sba_reject_as_busy_collision || sba_other_write_while_busy) begin
            sbbusyerror_q <= 1'b1;
        end else if (i_reg_we && (i_reg_addr == ADDR_SBCS) && i_reg_wdata[22]) begin
            sbbusyerror_q <= 1'b0;  // W1C
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sberror_q <= 3'd0;
        end else if (sberror_q == 3'd0 && sba_reject_as_invalid) begin
            sberror_q <= !sba_access_ok ? 3'd4 : 3'd3;  // 4=not supported, 3=misaligned
        end else if (sberror_q == 3'd0 && sba_busy_q && i_sba_err) begin
            sberror_q <= 3'd2;  // bad address (a real bus error)
        end else if (i_reg_we && (i_reg_addr == ADDR_SBCS) && (i_reg_wdata[14:12] != 3'd0)) begin
            sberror_q <= 3'd0;  // W1C
        end
    end

    // Plain configuration fields -- gated !sba_busy_q so a write attempted
    // mid-transaction is dropped (per spec) rather than silently
    // reconfiguring an access already in flight; sba_other_write_while_busy
    // above already flags this case via sbbusyerror.
    always_ff @(posedge clk) begin
        if (rst) begin
            sbreadonaddr_q    <= 1'b0;
            sbaccess_q        <= 3'd0;
            sbautoincrement_q <= 1'b0;
            sbreadondata_q    <= 1'b0;
        end else if (!sba_busy_q && i_reg_we && (i_reg_addr == ADDR_SBCS)) begin
            sbreadonaddr_q    <= i_reg_wdata[20];
            sbaccess_q        <= i_reg_wdata[19:17];
            sbautoincrement_q <= i_reg_wdata[16];
            sbreadondata_q    <= i_reg_wdata[15];
        end
    end

    /*
     * The actual bus request. o_sba_addr is dword-aligned (matching
     * design/core.sv's own mem_addr precedent -- the byte lane, not the
     * address, carries sub-dword position); o_sba_dat/i_sba_dat are
     * shifted by the byte offset within the 8-byte line, and sba_sel is
     * the byte-lane mask shifted to match -- same mask-and-shift
     * technique design/core.sv's own mem_sel/mem_wdata/mem_rdata_shifted
     * already use for ordinary loads/stores (see that file's own
     * comment crediting design/wb4_sram.sv's byte-enable convention).
     */
    wire [3:0] sba_width_bytes = (sbaccess_q == 3'd0) ? 4'd1 :
                                  (sbaccess_q == 3'd1) ? 4'd2 :
                                  (sbaccess_q == 3'd2) ? 4'd4 : 4'd8;
    wire [7:0] sba_width_mask  = (sbaccess_q == 3'd0) ? 8'b0000_0001 :
                                  (sbaccess_q == 3'd1) ? 8'b0000_0011 :
                                  (sbaccess_q == 3'd2) ? 8'b0000_1111 : 8'b1111_1111;

    assign o_sba_addr = {sbaddress0_q[31:3], 3'b0};
    assign o_sba_dat  = {sbdata1_q, sbdata0_q} << (sbaddress0_q[2:0] * 8);
    assign o_sba_sel  = sba_width_mask << sbaddress0_q[2:0];
    assign o_sba_we   = sba_we_q;
    assign o_sba_cyc  = sba_busy_q;
    assign o_sba_stb  = sba_busy_q;

    wire [63:0] sba_rdata_shifted = i_sba_dat >> (sbaddress0_q[2:0] * 8);

    always_ff @(posedge clk) begin
        if (rst) begin
            sba_busy_q <= 1'b0;
            sba_we_q   <= 1'b0;
        end else if (sba_busy_q) begin
            if (i_sba_ack || i_sba_err) sba_busy_q <= 1'b0;
        end else if (sba_start_real_op) begin
            sba_busy_q <= 1'b1;
            sba_we_q   <= sba_data_write_now;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sbaddress0_q <= 32'b0;
            sbdata0_q    <= 32'b0;
            sbdata1_q    <= 32'b0;
        end else if (sba_busy_q && i_sba_ack) begin
            // Hardware-driven completion update -- takes priority over a
            // same-cycle plain-write attempt, which the busy-collision
            // logic above already rejects (sba_busy_q was already 1 when
            // that write's own trigger evaluated), so there's no real
            // conflict between these two branches.
            if (!sba_we_q) begin
                sbdata0_q <= sba_rdata_shifted[31:0];
                if (sbaccess_q == 3'd3) sbdata1_q <= sba_rdata_shifted[63:32];
            end
            if (sbautoincrement_q) sbaddress0_q <= sbaddress0_q + {28'b0, sba_width_bytes};
        end else if (!sba_busy_q && i_reg_we) begin
            case (i_reg_addr)
                ADDR_SBADDRESS0: sbaddress0_q <= i_reg_wdata;
                ADDR_SBDATA0:    sbdata0_q    <= i_reg_wdata;
                ADDR_SBDATA1:    sbdata1_q    <= i_reg_wdata;
                default: ;
            endcase
        end
    end

    /* ----------------------------------------------------------------- *
     * sbaddress1-3/sbdata2-3 -- storage-only stubs, spec-optional given
     * this core's sbasize=32/max-sbaccess=64-bit (see the section header
     * above for why). progbuf_q -- the Program Buffer's own storage --
     * is declared here too (same array, same address decode as always),
     * but is no longer a stub: Milestone 7's own Program Buffer section
     * above reads it combinationally via o_progbuf_data, and
     * o_progbuf_start/progbuf_running_q (also above) drive real
     * execution through core0.
     * ----------------------------------------------------------------- */
    always_ff @(posedge clk) begin
        if (rst) begin
            sbaddress1_q <= 32'b0;
            sbaddress2_q <= 32'b0;
            sbaddress3_q <= 32'b0;
            sbdata2_q    <= 32'b0;
            sbdata3_q    <= 32'b0;
        end else if (i_reg_we) begin
            case (i_reg_addr)
                ADDR_SBADDRESS1: sbaddress1_q <= i_reg_wdata;
                ADDR_SBADDRESS2: sbaddress2_q <= i_reg_wdata;
                ADDR_SBADDRESS3: sbaddress3_q <= i_reg_wdata;
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
