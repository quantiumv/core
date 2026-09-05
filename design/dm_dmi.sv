// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: dm_dmi
 *
 * DMI transport (Milestone 6 of the EBREAK/JTAG staged plan -- see
 * [[dm-register-file-milestone]] for Milestone 5, which shipped design/dm.sv's
 * plain register interface this module is the real DMI-protocol front end
 * for). Owns the 41-bit DMI shift register's capture/update semantics and
 * the busy/sticky-error protocol (RISC-V Debug Spec ch. 6.1), and bridges
 * across this project's first-ever clock domain crossing: TCK (the JTAG
 * clock, driven by an external debugger, genuinely asynchronous to the
 * system clock -- no fixed frequency or phase relationship assumed) into
 * `clk` (dm.sv's own clock domain) and back.
 *
 * Instantiated by design/jtag_tap.sv, which owns the generic 16-state TAP
 * FSM, IR decode, and the IDCODE/DTMCS/BYPASS shift registers -- this
 * module owns only the DMI-specific shift register and the CDC bridge.
 * The TAP forwards Capture-DR/Shift-DR/Update-DR timing (as pulses/levels
 * on TCK) and TDI only while its own IR register selects DMI; this module
 * has no idea what IR value that corresponds to.
 *
 * DMI register layout (spec-fixed, 41 bits): address[6:0] at bits
 * [40:34], data[31:0] at bits [33:2], op[1:0] at bits [1:0]. Shifted
 * LSB-first (matches jtag_tap.sv's own shift-register convention exactly
 * -- see that file's header for why): `dmi_sr_q <= {tdi, dmi_sr_q[40:1]};
 * o_tdo = dmi_sr_q[0];`. op encodes the REQUEST on Update-DR (0=nop,
 * 1=read, 2=write, 3=reserved/unused as a request) and the RESULT status
 * on the following Capture-DR (0=success, 2=failed -- never produced by
 * this implementation, since nothing in dm.sv's own read/write path can
 * genuinely fail at the transport level -- 3=busy, meaning either the
 * previous operation hasn't completed yet or the debugger issued an
 * overlapping request while one was already in flight).
 *
 * CDC design: a request crosses TCK->clk as a toggle-synchronized pulse
 * (req_toggle_q, flipped on Update-DR whenever a new read/write is
 * accepted) paired with QUASI-STATIC address/data/we registers that are
 * read directly by clk-domain logic with no separate synchronizer of
 * their own -- safe specifically because the TCK side never touches them
 * again until the clk side's own completion toggle (resp_toggle_q) has
 * made the full round trip back, guaranteeing many clk cycles of
 * stability on both sides of every transition. The same toggle+
 * quasi-static-data pattern crosses the completion back clk->TCK. This
 * is a standard, well-established CDC idiom for "one outstanding request
 * at a time, data held stable for the whole round trip" -- not a full
 * 4-phase handshake, which isn't needed here since the DMI busy/retry
 * protocol itself already guarantees at most one request is ever in
 * flight.
 *
 * Reset domains: TCK-side state resets async on !trst_n (trst_n IS
 * explicitly asynchronous per 1149.1 -- that's its whole purpose).
 * clk-side state resets on `rst || (a synchronized view of !trst_n)` --
 * synchronizing trst_n into the clk domain and including it in the local
 * reset closes the CDC toggle-mismatch hazard for any reset sequence
 * where trst_n and rst overlap for at least ~2 clk cycles (the
 * realistic case: a debugger asserts TRST and holds it, rather than
 * pulsing it for a single cycle). One narrower, documented limitation
 * remains: dmihardreset firing while a request is genuinely mid-flight
 * in the clk domain can produce one spurious detected response toggle
 * once that in-flight operation eventually completes (the clk-domain
 * FSM has no way to know the TCK side gave up on it) -- accepted as a
 * rare, low-severity edge case rather than building a full cross-domain
 * abort handshake for a reset path real hardware has the same
 * fundamental difficulty with.
 */
module dm_dmi (
    input logic tck,
    input logic trst_n,

    /*
     * From jtag_tap.sv's generic DR-shift machinery -- driven only while
     * the TAP's own IR register currently selects DMI.
     */
    input  logic i_capture_dr,  // pulse, coincides with CaptureDR state entry
    input  logic i_shift_dr,    // level, high throughout ShiftDR
    input  logic i_update_dr,   // pulse, coincides with UpdateDR state entry
    input  logic i_tdi,
    output logic o_tdo,

    // From jtag_tap.sv's DTMCS handling (dmireset/dmihardreset W1 bits).
    input  logic i_dmireset,
    input  logic i_dmihardreset,
    output logic [1:0] o_dmistat,  // for dtmcs.dmistat readback: 0=ok, 3=sticky busy -- same encoding as the DMI register's own op-status field (see the module header)

    /*
     * dm.sv's own plain register interface (clk domain) -- see
     * design/dm.sv's header for its exact timing contract (i_reg_we is a
     * single-cycle enable, o_reg_rdata is combinational off i_reg_addr).
     */
    input  logic clk,
    input  logic rst,
    output logic [6:0]  o_reg_addr,
    output logic [31:0] o_reg_wdata,
    output logic        o_reg_we,
    input  logic [31:0] i_reg_rdata
);

    /* ----------------------------------------------------------------- *
     * TCK domain: the 41-bit DMI shift register and the busy/sticky-
     * error protocol.
     *
     * Every register in this section carries an explicit initial value,
     * not just a reset arm -- matching design/jtag_tap.sv's own fix for
     * the identical, confirmed gotcha: a constant-tied trst_n (e.g.
     * soc.sv's own ANSI default, used by every pre-existing testbench
     * that doesn't know these pins exist) never produces a genuine
     * `negedge trst_n` event in this project's Icarus build, so without
     * an initial value these registers would sit at their power-on-X
     * value indefinitely whenever no real JTAG probe is present. This
     * is the whole set -- resp_toggle_q, below, is the one exception:
     * it's a CLK-domain register (driven by `posedge clk`, not `posedge
     * tck`), and clk genuinely toggles in every testbench, so its own
     * reset arm already fires for real with no such gap.
     *
     * Verilator's PROCASSINIT check flags every one of these as
     * "redundant" against its own reset arm -- true for a simulator
     * that always drives a real reset edge, but not the point: the
     * initial value is what keeps this design correct under the
     * Icarus-specific gotcha above, which Verilator itself is immune
     * to. Suppressed deliberately, not silenced blindly.
     * ----------------------------------------------------------------- */
    /* verilator lint_off PROCASSINIT */
    logic [40:0] dmi_sr_q = 41'b0;
    assign o_tdo = dmi_sr_q[0];

    logic [6:0]  pending_addr_q = 7'b0;
    logic [31:0] pending_data_q = 32'b0;
    logic        pending_we_q = 1'b0;
    logic        outstanding_q = 1'b0;
    logic        busy_sticky_q = 1'b0;
    logic        req_toggle_q = 1'b0;

    logic [31:0] result_data_q = 32'b0;
    logic [6:0]  result_addr_q = 7'b0;

    // resp_toggle_q lives in the clk domain (declared below) but is read
    // here via the 2FF+edge-detect synchronizer immediately following.
    logic resp_toggle_q;
    logic [2:0] resp_sync_q = 3'b0;
    /* verilator lint_on PROCASSINIT */
    always_ff @(posedge tck or negedge trst_n) begin
        if (!trst_n) resp_sync_q <= 3'b0;
        else         resp_sync_q <= {resp_sync_q[1:0], resp_toggle_q};
    end
    wire resp_pulse = resp_sync_q[2] ^ resp_sync_q[1];

    // clk-domain read result, captured here once resp_pulse confirms it's
    // stable (see the module header's quasi-static-data argument).
    logic [31:0] resp_data_q;

    always_ff @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            dmi_sr_q       <= 41'b0;
            outstanding_q  <= 1'b0;
            busy_sticky_q  <= 1'b0;
            req_toggle_q   <= 1'b0;
            pending_addr_q <= 7'b0;
            pending_data_q <= 32'b0;
            pending_we_q   <= 1'b0;
            result_data_q  <= 32'b0;
            result_addr_q  <= 7'b0;
        end else begin
            if (i_capture_dr) begin
                dmi_sr_q <= {result_addr_q, result_data_q,
                             (outstanding_q || busy_sticky_q) ? 2'd3 : 2'd0};
            end else if (i_shift_dr) begin
                dmi_sr_q <= {i_tdi, dmi_sr_q[40:1]};
            end else if (i_update_dr) begin
                // op field, freshly shifted in, valid the instant Update-DR
                // is entered.
                if (dmi_sr_q[1:0] == 2'd1 || dmi_sr_q[1:0] == 2'd2) begin
                    if (outstanding_q || busy_sticky_q) begin
                        busy_sticky_q <= 1'b1;
                    end else begin
                        pending_addr_q <= dmi_sr_q[40:34];
                        pending_data_q <= dmi_sr_q[33:2];
                        pending_we_q   <= (dmi_sr_q[1:0] == 2'd2);
                        outstanding_q  <= 1'b1;
                        req_toggle_q   <= ~req_toggle_q;
                    end
                end
            end

            if (i_dmihardreset || i_dmireset) begin
                busy_sticky_q <= 1'b0;
            end

            if (resp_pulse) begin
                outstanding_q <= 1'b0;
                result_data_q <= resp_data_q;
                result_addr_q <= pending_addr_q;
            end
        end
    end

    // Same encoding as the DMI register's own op-status field above
    // (0=success, 3=busy) -- an earlier draft used 2'd2 here, silently
    // reusing the "failed" code this module's header says it never
    // produces, for the identical busy_sticky_q condition the DMI
    // register itself correctly reports as 3.
    assign o_dmistat = busy_sticky_q ? 2'd3 : 2'd0;

    /* ----------------------------------------------------------------- *
     * clk domain: synchronize the request toggle in, drive dm.sv's plain
     * interface over a fixed 3-cycle sequence, synchronize the
     * completion toggle back out.
     * ----------------------------------------------------------------- */
    /*
     * trst_n is deliberately used BOTH ways in this design: as a genuine
     * async reset trigger in the TCK domain above and jtag_tap.sv's own
     * FSM (real 1149.1 TRST_N semantics), and, here, as a plain
     * synchronously-sampled data input being 2FF-synchronized into the
     * clk domain -- exactly the module header's own documented "close
     * the CDC toggle-mismatch hazard" design, not an accidental dual
     * use Verilator's SYNCASYNCNET check is right to flag in general.
     */
    /* verilator lint_off SYNCASYNCNET */
    logic [1:0] trst_n_sync_q;
    always_ff @(posedge clk) trst_n_sync_q <= {trst_n_sync_q[0], trst_n};
    /* verilator lint_on SYNCASYNCNET */
    wire clk_domain_rst = rst || !trst_n_sync_q[1];

    logic [2:0] req_sync_q;
    always_ff @(posedge clk) begin
        if (clk_domain_rst) req_sync_q <= 3'b0;
        else                req_sync_q <= {req_sync_q[1:0], req_toggle_q};
    end
    wire req_pulse = req_sync_q[2] ^ req_sync_q[1];

    logic [1:0] delay_q;  // 0=idle/wait-for-req, 1=addr/wdata posted, 2=we asserted + rdata captured next edge

    always_ff @(posedge clk) begin
        if (clk_domain_rst) begin
            o_reg_we      <= 1'b0;
            resp_toggle_q <= 1'b0;
            delay_q       <= 2'd0;
        end else begin
            o_reg_we <= 1'b0;  // one-shot pulse, deasserts every cycle by default
            case (delay_q)
                2'd0: if (req_pulse) begin
                    o_reg_addr  <= pending_addr_q;  // direct cross-domain read of a quasi-static TCK reg -- see header
                    o_reg_wdata <= pending_data_q;
                    delay_q     <= 2'd1;
                end
                2'd1: begin
                    o_reg_we <= pending_we_q;  // fires the actual dm.sv write on this edge if it's a WRITE
                    delay_q  <= 2'd2;
                end
                2'd2: begin
                    resp_data_q   <= i_reg_rdata;  // o_reg_addr has been stable since delay_q==0's edge
                    resp_toggle_q <= ~resp_toggle_q;
                    delay_q       <= 2'd0;
                end
                default: delay_q <= 2'd0;
            endcase
        end
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
