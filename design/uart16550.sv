// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: uart16550
 *
 * A real, addressable Wishbone-slave peripheral: a register-compatible
 * (not timing-compatible) model of a real 16550 UART -- CLINT/UART
 * standards-compliance plan Milestone 3. Replaces both design/uart_tx.sv
 * and design/uart_rx.sv (retired once soc.sv's own Milestone 4
 * integration lands): a real 16550 is architecturally ONE device, and
 * this module is too. Internally this still "transmits" via $write
 * immediately on a THR write and "receives" via the same push_byte
 * testbench backdoor uart_rx.sv used -- there is no bit-banged serial
 * output, no baud-rate model, and no shift-register delay anywhere in
 * this milestone, same deliberate simplification uart_tx.sv's own header
 * already documented (the goal is a real program printing/receiving real
 * bytes in an iverilog run against REAL 16550 register semantics, not
 * hardware-accurate serial timing).
 *
 * Registered, 1-wait-state ack, matching every sibling peripheral's own
 * house style (clint.sv/plic.sv/uart_tx.sv) exactly.
 *
 * Register map -- all 8 real 16550 registers live at byte offsets 0-7 of
 * ONE 64-bit dword at UART_BASE (0x0400_8000, unchanged from before this
 * milestone) -- addressed PURELY via sel_i (which byte lane(s) a given
 * access's own address naturally produces) and lcr_q[7] (DLAB), mirroring
 * design/plic.sv's own established sub-dword-register pattern. No
 * addr_i decode happens inside this module at all -- addr_i's every bit
 * is genuinely don't-care here (wb_addr_decoder.sv already routed a
 * request here; sel_i already tells this module exactly which byte(s) of
 * the one dword a real LB/SB/LW/SW/LD/SD produced, the same byte-
 * addressable-64-bit-bus convention clint.sv's own per-lane mtimecmp
 * write and plic.sv's own dword-half select both already rely on).
 * REAL FIRMWARE MUST USE BYTE-WIDTH (LB/LBU/SB) ACCESSES to these
 * registers, same as real 16550 driver code always does -- a wider
 * access (e.g. a 4-byte LW/SW at offset 0) would span FOUR distinct
 * 1-byte registers at once (RBR/IER/IIR/LCR), not one 4-byte register;
 * this is a genuine, load-bearing consequence of packing 8 real
 * registers into one dword rather than each getting its own 8-byte-
 * aligned slot the way uart_tx.sv/uart_rx.sv/clint.sv's own registers
 * did -- found while porting firmware/uart_plic_meip_test.s's/
 * uart_plic_seip_test.s's own RX_DATA pop off `lw` (see this plan's own
 * implementation notes): a real 16550 driver was ALREADY expected to use
 * byte accesses, so this is a correctness fix uncovered by, not
 * introduced by, this rewrite.
 *
 *   +0  RBR/THR  DLAB=0: read pops the oldest queued byte (zero-extended,
 *                    mirrors uart_rx.sv's own RX_DATA exactly, including
 *                    "reads 0 when empty, never underflows") and
 *                    advances the queue; write "prints" immediately
 *                    (mirrors uart_tx.sv's own TX_DATA exactly) and
 *                    arms/re-arms the THRE one-shot (see below).
 *                DLAB=1: DLL, plain RW storage, no functional effect
 *                    (this model has no real baud generator).
 *   +1  IER      DLAB=0: interrupt-enable. Bit 0 (RDA) and bit 1 (THRE)
 *                    are REAL and functionally gate o_irq (see below).
 *                    Bits 2 (RLS)/3 (MSI) are accepted/stored but
 *                    structurally can never fire -- no real line-status
 *                    or modem-status error condition is ever generated
 *                    in this model, matching this plan's own explicit
 *                    scope limit.
 *                DLAB=1: DLM, plain RW storage, same as DLL.
 *   +2  IIR/FCR  Read: IIR (interrupt identification, see the priority
 *                    encode below). Write: FCR -- only bit 0 (FIFO
 *                    enable) has a real, observable effect (IIR's own
 *                    bits[7:6] read back 2'b11 when set, matching real
 *                    16550A auto-detection); every other FCR bit is
 *                    accepted and silently ignored (this model's RX/TX
 *                    queues have no real hardware FIFO reset/trigger-
 *                    level concept to apply them to). Independent of
 *                    DLAB (real 16550 hardware: FCR/IIR live at this
 *                    offset regardless of DLAB).
 *   +3  LCR      Read/write, full 8-bit fidelity, independent of DLAB
 *                    (LCR is WHERE DLAB, bit 7, itself lives). Word
 *                    length/stop-bit/parity/break-control bits are
 *                    plain storage with no functional effect in this
 *                    model (no real framing to apply them to) -- LCR's
 *                    only REAL effect anywhere in this module is DLAB
 *                    gating offsets 0/1 above.
 *   +4  MCR      Read/write. Bits[4:0] are plain storage; bits[7:5] read
 *                    back forced 0 (real silicon's reserved-bit
 *                    behavior). No functional gating anywhere -- Linux's
 *                    own MMIO 8250 driver path doesn't require OUT2 to
 *                    gate anything (that's ISA-legacy-only), confirmed
 *                    against primary references.
 *   +5  LSR      Read-only. Bit 0 (DR) = real, tracks rx_count>0. Bit 1
 *                    (OE) = real -- push_byte's own silent-drop-on-
 *                    overflow condition sets it, an LSR read clears it
 *                    (spec-correct), and it is wired into LSR *status*
 *                    ONLY, never into o_irq (RLS/IER-bit2 stays
 *                    structurally out of scope, per this plan's own
 *                    decision). Bits 5 (THRE) and 6 (TEMT) are BOTH
 *                    hardwired 1 (honest given no shift-register delay
 *                    exists in this zero-latency model) -- a *status*-
 *                    bit simplification only; the THRE *interrupt* below
 *                    is fully real, not hardwired. Bits[4:2]/7 are
 *                    always 0 (no parity/framing/break/FIFO error is
 *                    ever generated). Write: ignored (LSR has no real
 *                    register to write to).
 *   +6  MSR      Fully hardwired 8'b1011_0000 (CTS/DSR/DCD=1, RI=0, all
 *                    4 delta bits 0) so no modem-ready poll loop ever
 *                    stalls -- ***a corrected value, not the plan's own
 *                    literal 8'b0111_0000***: the plan's own prose
 *                    ("CTS/DSR/DCD=1, RI=0") and its own literal
 *                    contradict each other against the real MSR bit
 *                    layout (bit4=CTS, bit5=DSR, bit6=RI, bit7=DCD) --
 *                    0111_0000 actually encodes RI=1/DCD=0, the OPPOSITE
 *                    of the stated intent, while 1011_0000 (CTS=1 at
 *                    bit4, DSR=1 at bit5, RI=0 at bit6, DCD=1 at bit7)
 *                    genuinely matches it. Implemented here as the
 *                    corrected value; flagged for visibility per this
 *                    project's own honesty standard, not silently
 *                    "fixed" with no trace. Write: ignored.
 *   +7  SCR      Read/write, plain scratch storage, no functional effect
 *                    anywhere (real 16550 hardware: SCR is pure
 *                    software-visible scratch space by spec, nothing
 *                    else has ever read or written it here).
 *
 * o_irq (feeds design/plic.sv's i_uart_rx_irq unchanged, same LEVEL
 * contract mtip_o/plic.sv's own gateway already depend on): the real OR
 * of two independent pending conditions --
 *   RDA pending  = (rx_count > 0) && ier_q[0]. Replaces uart_rx.sv's own
 *       unconditional `o_rx_irq = rx_count>0` -- this is the one
 *       behavior change every existing UART-RX-interrupt firmware test
 *       must account for (see firmware/uart_plic_*_test.s's own new
 *       IER-arming instruction). Level-based, not latched: it tracks
 *       rx_count/ier_q live, exactly like the old o_rx_irq did.
 *   THRE pending = a real one-shot register (thre_pending_q), per the
 *       user's own full-fidelity choice over the simpler always-poll-TX
 *       alternative. SET one cycle after a THR write commits, gated on
 *       ier_q[1]'s value AT THAT SAME CYCLE (a deliberate,
 *       simpler-than-strictly-spec choice already flagged as a live
 *       design decision in the plan itself -- not re-litigated here).
 *       CLEARED on an IIR read that genuinely reports THRE as the cause
 *       (i.e. RDA is NOT also pending -- RDA always outranks THRE, see
 *       the priority encode below); a NEW THR write while already
 *       pending immediately masks o_irq's own THRE contribution for
 *       exactly that one cycle (via thr_write_this_cycle below) and
 *       re-arms one cycle later -- a real, observable one-cycle
 *       clear-then-immediate-rearm transition, not a silent no-op.
 *
 * IIR priority encode (highest to lowest, real spec order): Receiver-
 * Line-Status (never fires, no RLS condition exists) > RDA > Character-
 * Timeout (deliberately skipped -- refines WHEN RDA fires, not WHETHER;
 * out of scope per the plan) > THRE > Modem-Status (never fires, no MSI
 * condition exists). Bit 0 is ACTIVE-LOW (0 = an interrupt is pending).
 * ID encoding: RDA=3'b010, THRE=3'b001, none=3'b000 -- both directed
 * tests and this plan's own revert-and-recheck mutants (see this
 * module's own verification) depend on RDA's real priority over THRE
 * being enforced by the `if (rda_pending) ... else if (thre_pending_q)
 * ...` order below, not just by coincidence.
 */
module uart16550 (
    input logic clk,
    input logic rst,

    /*
     * addr_i is genuinely, entirely unused -- see this file's own header
     * for why (every register lives at a fixed byte lane of ONE dword;
     * sel_i alone says which). Wrapped the same way clint.sv/plic.sv
     * already wrap their own upstream-decided address bits.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] addr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    /*
     * dat_i[55:37] and dat_i[23:17] are genuinely, permanently unused --
     * not an oversight, and not addr_i's "upstream already decided this"
     * situation either: these are real WRITE-DATA bits for real
     * registers whose write paths this module deliberately doesn't
     * implement in full. dat_i[55:48] (MSR) and dat_i[47:40] (LSR) are
     * never read at all -- both are read-only per real 16550 spec (see
     * this file's own header), so their own write paths simply don't
     * exist. dat_i[39:37] (MCR's own reserved bits[7:5] within its byte)
     * and dat_i[23:17] (FCR's own bits[7:1] within its byte, everything
     * but the one real FIFO-enable bit) are real per-spec reserved/
     * inert fields this module accepts-and-ignores by construction (see
     * header's own MCR/FCR entries) -- there is no missing logic here,
     * only fields with genuinely no effect to wire up.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] dat_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0] dat_o,
    /*
     * sel_i[6] (MSR's own byte lane) is genuinely, permanently unused --
     * MSR is fully hardwired and read-only (see header), so it has no
     * write path at all to gate with its own select bit. Every other
     * sel_i bit IS read somewhere below.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [7:0]  sel_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic         we_i,
    input  logic         cyc_i,
    input  logic         stb_i,
    output logic         ack_o,
    output logic         err_o,

    output logic o_irq
);
    wire bus_fire = cyc_i && stb_i;

    /*
     * Simulation-only capture of every transmitted character, for
     * testbench-side checking via a hierarchical reference (e.g.
     * dut.uart0.tx_history) -- SAME names as uart_tx.sv's own
     * tx_history/tx_history_count, deliberately, since several
     * testbenches hierarchically reference them (see this plan's own
     * "keep the instance name uart0" decision).
     */
    localparam TX_HISTORY_DEPTH = 256;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] tx_history [0:(TX_HISTORY_DEPTH - 1)];
    /* verilator lint_on UNUSEDSIGNAL */
    logic [$clog2(TX_HISTORY_DEPTH):0] tx_history_count;

    /*
     * Simulation-only inbound-byte queue, populated via push_byte and
     * drained by real RBR bus reads -- SAME names/shape as uart_rx.sv's
     * own rx_queue/rx_head/rx_tail/rx_count/push_byte, deliberately, for
     * the same hierarchical-reference reason.
     */
    localparam RX_QUEUE_DEPTH = 256;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] rx_queue [0:(RX_QUEUE_DEPTH - 1)];
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0] rx_head;
    logic [7:0] rx_tail;
    logic [$clog2(RX_QUEUE_DEPTH):0] rx_count;

    /*
     * push_byte: simulation-only backdoor a testbench calls to enqueue a
     * byte as if it had just arrived over the wire -- identical contract
     * to uart_rx.sv's own push_byte (blocking assignment deliberately;
     * see that file's own header for why). Overflow now ALSO sets oe_q
     * (new this milestone, LSR's own OE bit) in addition to the
     * pre-existing silent-drop -- closes the "OE" open question the plan
     * itself names, without touching o_irq (OE is wired into LSR status
     * only, per this module's own header).
     */
    logic oe_q;
    task push_byte(input logic [7:0] b);
        if (rx_count < RX_QUEUE_DEPTH) begin
            rx_queue[rx_tail] = b;
            rx_tail = rx_tail + 8'b1;
            rx_count = rx_count + 1'b1;
        end else begin
            oe_q = 1'b1;
        end
    endtask

    logic [7:0] lcr_q;
    logic [4:0] mcr_q;
    logic [3:0] ier_q;
    logic [7:0] scr_q;
    logic [7:0] dll_q;
    logic [7:0] dlm_q;
    logic       fcr_enable_q;
    logic       thre_pending_q;

    wire dlab = lcr_q[7];

    // RDA: level, live off rx_count/ier_q -- see this file's own header.
    wire rda_pending = (rx_count > 0) && ier_q[0];

    // IIR priority encode -- RDA always outranks THRE; see header.
    logic [2:0] iir_id;
    always_comb begin
        if (rda_pending)         iir_id = 3'b010;
        else if (thre_pending_q) iir_id = 3'b001;
        else                     iir_id = 3'b000;
    end
    wire pending_any     = rda_pending || thre_pending_q;
    wire iir_reports_thre = !rda_pending && thre_pending_q;
    wire [7:0] iir_val = {(fcr_enable_q ? 2'b11 : 2'b00), 2'b00, iir_id, ~pending_any};

    wire [7:0] lsr_val = {1'b0, 1'b1, 1'b1, 3'b000, oe_q, (rx_count > 0)};
    // MSR: hardwired -- see this file's own header for the corrected
    // literal (1011_0000, not the plan's own inconsistent 0111_0000).
    wire [7:0] msr_val = 8'b1011_0000;

    // A THR write's own effect on o_irq is masked for exactly the one
    // cycle it happens on -- see header's "one-cycle clear-then-
    // immediate-rearm" paragraph, and this plan's own "bonus" mutant.
    wire thr_write_this_cycle = bus_fire && we_i && sel_i[0] && !dlab;
    assign o_irq = rda_pending || (thre_pending_q && !thr_write_this_cycle);

    always @(posedge clk) begin
        if (rst) begin
            ack_o            <= 1'b0;
            err_o            <= 1'b0;
            dat_o            <= 64'b0;
            lcr_q            <= 8'b0;
            mcr_q            <= 5'b0;
            ier_q            <= 4'b0;
            scr_q            <= 8'b0;
            dll_q            <= 8'b0;
            dlm_q            <= 8'b0;
            fcr_enable_q     <= 1'b0;
            thre_pending_q   <= 1'b0;
            oe_q             <= 1'b0;
            tx_history_count <= '0;
            rx_head          <= 8'b0;
            rx_tail          <= 8'b0;
            rx_count         <= '0;
        end else if (bus_fire) begin
            ack_o <= 1'b1;
            err_o <= 1'b0;

            if (we_i) begin
                if (sel_i[0] && !dlab) begin
                    // THR write -- prints immediately, mirrors
                    // uart_tx.sv's own TX_DATA exactly.
                    $write("%c", dat_i[7:0]);
                    $fflush;
                    if (tx_history_count < TX_HISTORY_DEPTH) begin
                        tx_history[tx_history_count[7:0]] <= dat_i[7:0];
                        tx_history_count <= tx_history_count + 1'b1;
                    end
                end
                if (sel_i[0] && dlab)  dll_q        <= dat_i[7:0];
                if (sel_i[1] && !dlab) ier_q        <= dat_i[11:8];
                if (sel_i[1] && dlab)  dlm_q        <= dat_i[15:8];
                if (sel_i[2])          fcr_enable_q <= dat_i[16];
                if (sel_i[3])          lcr_q        <= dat_i[31:24];
                if (sel_i[4])          mcr_q        <= dat_i[36:32];
                if (sel_i[7])          scr_q        <= dat_i[63:56];
            end else begin
                // RBR pop -- mirrors uart_rx.sv's own RX_DATA pop
                // exactly, gated the same way (sel_i[0], DLAB=0, queue
                // non-empty).
                if (sel_i[0] && !dlab && (rx_count > 0)) begin
                    rx_head  <= rx_head + 8'b1;
                    rx_count <= rx_count - 1'b1;
                end
                // LSR read clears OE -- see this file's own header.
                if (sel_i[5]) oe_q <= 1'b0;
            end

            // THRE one-shot set/re-arm/clear -- see this file's own
            // header for the full timing proof.
            if (we_i && sel_i[0] && !dlab)
                thre_pending_q <= ier_q[1];
            else if (!we_i && sel_i[2] && iir_reports_thre)
                thre_pending_q <= 1'b0;

            dat_o <= { scr_q, msr_val, lsr_val, {3'b0, mcr_q}, lcr_q, iir_val,
                       (dlab ? dlm_q : {4'b0, ier_q}),
                       (dlab ? dll_q : ((rx_count > 0) ? rx_queue[rx_head] : 8'b0)) };
        end else begin
            ack_o <= 1'b0;
            err_o <= 1'b0;
        end
    end
    /*
     * err_o is intentionally never asserted -- no error conditions are
     * defined for this peripheral, same reasoning as every sibling
     * peripheral's own identical comment: wb_addr_decoder.sv is the only
     * thing that ever routes a request here.
     */

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
