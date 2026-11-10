/*
 * lockstep_irq.sv -- Mode A interrupt injection (pipelining track plan,
 * P3.4). Instantiated once per side, driven off that side's OWN
 * retirement stream, so two sides retiring the same instruction sequence
 * see identical injected timing even though they run on independent
 * clocks with independently perturbed bus delay. Levels are a pure
 * function of retirement index and SEED, only ever cleared by a retired
 * store to the MAGIC_CLR register (observed via RVFI/the MMIO write
 * strobe, not by snooping the bus mid-transaction) -- matching
 * gen/qvgen.py's M/S-mode trap handlers, which blindly write 1 to
 * MAGIC_CLR without distinguishing which line fired.
 *
 * IRQ_MODE: 0 = disabled (never asserts; this is the default, and
 * matches every pre-P3.4 corpus run byte for byte), 1 = MTIP only,
 * 2 = MTIP+MEIP+SEIP.
 *
 * late_i delays every level change by one more cycle, so a new level is
 * first visible two cycles after the retirement that raised it instead
 * of one. A core that samples interrupts only in the cycle right after a
 * retirement (the rule both ref_core and the pipelined core follow) then misses it
 * there and takes it after the NEXT retirement; one that samples a cycle
 * late (QV_MUTANT==5) takes it a retirement earlier, so the retirement
 * streams differ. Without late_i both kinds take it at the same boundary.
 *
 * Mode B (bnd_mode_i, lockstep_tb.sv): the other side retires in groups and samples only after a group, so this side
 * (the reference) may see a level change only where a group ended (bnd_i: this retirement ends one). The levels
 * still step per retirement; what this side sees is latched at each boundary, and with late_i at the boundary after
 * that (the group after the one that raised it: what a core that samples after each group sees one cycle late).
 */
module lockstep_irq (
    input  logic clk,
    input  logic rst,

    input  logic [31:0]  density_i,        // runtime: ~density_i/256 chance of a new assert per retirement, per line

    input  logic [31:0]  irq_mode_i,       // runtime: 0=disabled, 1=MTIP only, 2=MTIP+MEIP+SEIP
    input  logic [31:0]  seed_i,           // runtime: re-seeds the LFSR at reset
    input  logic         late_i,           // runtime: level changes visible one cycle later
    input  logic         bnd_mode_i,       // runtime: mode B, the levels this side sees change only at boundaries
    input  logic         bnd_i,            // (mode B) this cycle's retirement ends a group of the other side's

    input  logic         rvfi_valid,       // this side's own retirement pulse
    input  logic         magic_clr_we,     // this side's own retired store to MAGIC_CLR
    input  logic [31:0]  magic_clr_wdata,

    output logic o_mtip,
    output logic o_meip,
    output logic o_seip
);
    logic [31:0] lfsr_q;
    wire  [31:0] lfsr_next = lfsr_q ^ (lfsr_q << 13) ^ (lfsr_q >> 17) ^ (lfsr_q << 5);

    logic pending_mtip_q, pending_meip_q, pending_seip_q;
    wire  do_clear = magic_clr_we && (magic_clr_wdata != 32'b0);

    // the levels after this cycle's retirement (a clear wins over a new assert)
    logic n_mtip, n_meip, n_seip;
    always_comb begin
        n_mtip = pending_mtip_q;
        n_meip = pending_meip_q;
        n_seip = pending_seip_q;
        if (do_clear) begin
            n_mtip = 1'b0;
            n_meip = 1'b0;
            n_seip = 1'b0;
        end else if (irq_mode_i != 32'b0 && rvfi_valid) begin
            if (lfsr_next[7:0] < density_i[7:0])                           n_mtip = 1'b1;
            if (irq_mode_i >= 32'd2 && lfsr_next[15:8] < density_i[7:0])  n_meip = 1'b1;
            if (irq_mode_i >= 32'd2 && lfsr_next[23:16] < density_i[7:0]) n_seip = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            lfsr_q         <= (seed_i == 32'b0) ? 32'hC0FF_EE11 : seed_i;
            pending_mtip_q <= 1'b0;
            pending_meip_q <= 1'b0;
            pending_seip_q <= 1'b0;
        end else begin
            if (irq_mode_i != 32'b0 && rvfi_valid) lfsr_q <= lfsr_next;
            pending_mtip_q <= n_mtip;
            pending_meip_q <= n_meip;
            pending_seip_q <= n_seip;
        end
    end

    logic late_mtip_q, late_meip_q, late_seip_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            late_mtip_q <= 1'b0;
            late_meip_q <= 1'b0;
            late_seip_q <= 1'b0;
        end else begin
            late_mtip_q <= pending_mtip_q;
            late_meip_q <= pending_meip_q;
            late_seip_q <= pending_seip_q;
        end
    end

    // mode B: vis_* is what this side sees, prv_* the levels at the last boundary (for late_i)
    logic vis_mtip_q, vis_meip_q, vis_seip_q, prv_mtip_q, prv_meip_q, prv_seip_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            {vis_mtip_q, vis_meip_q, vis_seip_q} <= 3'b0;
            {prv_mtip_q, prv_meip_q, prv_seip_q} <= 3'b0;
        end else if (rvfi_valid && bnd_i) begin
            {prv_mtip_q, prv_meip_q, prv_seip_q} <= {n_mtip, n_meip, n_seip};
            {vis_mtip_q, vis_meip_q, vis_seip_q} <= late_i ? {prv_mtip_q, prv_meip_q, prv_seip_q}
                                                           : {n_mtip, n_meip, n_seip};
        end
    end

    assign o_mtip = bnd_mode_i ? vis_mtip_q : late_i ? late_mtip_q : pending_mtip_q;
    assign o_meip = bnd_mode_i ? vis_meip_q : late_i ? late_meip_q : pending_meip_q;
    assign o_seip = bnd_mode_i ? vis_seip_q : late_i ? late_seip_q : pending_seip_q;
endmodule
