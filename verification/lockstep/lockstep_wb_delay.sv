/*
 * lockstep_wb_delay.sv -- inserts a seeded random 0..DELAY_MAX wait
 * states before forwarding a newly-issued Wishbone B4 classic request
 * downstream. Once forwarded, the request's address/data/sel/we/lock are
 * held stable and cyc/stb stay asserted until ack or err -- the "never
 * abandon a Wishbone request" rule the whole pipelining track depends on
 * (see the plan's Key decisions section).
 *
 * DELAY_MAX=0 makes this module a pure combinational passthrough with no
 * added latency at all. DELAY_MAX>0 adds a minimum of 1 registered cycle
 * even on the "0 wait states" draw, since a request must be latched
 * before it can be reissued -- deliberate, and harmless for the timing
 * perturbation this exists to provide.
 *
 * RESOLVED (characterization, not an RTL bug): with DELAY_MAX>0, some
 * DLY_SEED_A/DLY_SEED_B pairs make a REF-vs-REF run (both sides
 * QV_MUTANT=0, flat SRAM both sides) retire far more instructions than
 * the program actually needs -- e.g. verification/riscv-arch-test's
 * I-add-00.elf, confirmed via the standalone testbench/rvfi_tracer.sv to
 * need exactly 4327 retirements, instead passes 19699 and still climbing
 * at a 300,000-cycle timeout under DELAY_MAX=8 DLY_SEED_A=3 DLY_SEED_B=4
 * (reproduced exactly: same seed pair, same 19699) -- yet DLY_SEED_A=11
 * DLY_SEED_B=97 at the same DELAY_MAX completes cleanly in 4399. This is
 * the exact same mechanism as lockstep_mem.sv's own (resolved) cache-
 * config KNOWN GAP comment, not a protocol hazard in the FSM below --
 * see that comment for the full explanation. In short: this module makes
 * one side's bus transactions randomly slower than the other's, which
 * lets the relatively-faster side keep retiring past its own tohost
 * write while lockstep_tb.sv's completion check (deliberately) waits for
 * BOTH sides' comparator rings to drain. I-add-00.elf's own RVMODEL_HALT
 * epilogue ends in a bare EBREAK with mtvec never configured, so running
 * past completion means re-taking that EBREAK to mtvec's reset value of
 * 0 -- the reset vector -- restarting the whole program, rather than a
 * harmless few extra cycles. DLY_SEED_A=11/DLY_SEED_B=97 simply doesn't
 * skew the two sides far enough apart to reach that EBREAK before the
 * rings drain; DLY_SEED_A=3/DLY_SEED_B=4 does. No LOCKSTEP_DIVERGENCE is
 * ever reported in the overrun case because both sides independently
 * re-run the identical program, so they never disagree with each other.
 * run_lockstep.sh defaults to DELAY_MAX=0 for exactly this reason --
 * every zero-delay run is unaffected by this (no relative skew to
 * exploit); DELAY_MAX>0 remains off by default pending a deliberate
 * decision on completion-detection semantics (see lockstep_mem.sv's
 * comment), not because this module's own FSM is suspect.
 */

module lockstep_wb_delay #(
    parameter int DELAY_MAX = 0    // structural: 0 permanently disables the FSM below
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [31:0] seed_i,    // runtime: re-seeds the LFSR at reset

    // upstream (master-facing) slave port
    input  logic [31:0] up_addr_i,
    input  logic [63:0] up_dat_i,
    output logic [63:0] up_dat_o,
    input  logic [7:0]  up_sel_i,
    input  logic        up_we_i,
    input  logic        up_cyc_i,
    input  logic        up_stb_i,
    output logic        up_ack_o,
    output logic        up_err_o,
    input  logic        up_lock_i,

    // downstream (slave-facing) master port
    output logic [31:0] dn_addr_o,
    output logic [63:0] dn_dat_o,
    input  logic [63:0] dn_dat_i,
    output logic [7:0]  dn_sel_o,
    output logic        dn_we_o,
    output logic        dn_cyc_o,
    output logic        dn_stb_o,
    input  logic        dn_ack_i,
    input  logic        dn_err_i,
    output logic        dn_lock_o
);
    // Declared at module scope, not inside the generate block below --
    // iverilog fails to resolve a typedef'd enum's literal names
    // (`Unable to bind wire/reg/memory 'S_REQ'`) when the typedef lives
    // inside a named generate block, confirmed by hitting it directly
    // once DELAY_MAX>0 first elaborated the g_delay branch (every earlier
    // compile had used the default DELAY_MAX=0, which never exercised
    // this branch at all). Unused but harmless under g_passthrough.
    typedef enum logic [1:0] {S_IDLE, S_WAIT, S_REQ} state_t;

    generate
        if (DELAY_MAX == 0) begin : g_passthrough
            assign dn_addr_o = up_addr_i;
            assign dn_dat_o  = up_dat_i;
            assign dn_sel_o  = up_sel_i;
            assign dn_we_o   = up_we_i;
            assign dn_cyc_o  = up_cyc_i;
            assign dn_stb_o  = up_stb_i;
            assign dn_lock_o = up_lock_i;
            assign up_dat_o  = dn_dat_i;
            assign up_ack_o  = dn_ack_i;
            assign up_err_o  = dn_err_i;
        end else begin : g_delay
            localparam int CW = $clog2(DELAY_MAX + 1);

            state_t        state_q;
            logic [CW-1:0] wait_cnt_q;
            logic [31:0]   lfsr_q;
            logic [31:0]   addr_q;
            logic [63:0]   dat_q;
            logic [7:0]    sel_q;
            logic          we_q;
            logic          lock_q;

            // xorshift32, re-seeded from the SEED parameter -- deterministic
            // per seed (no $random), so a given seed reproduces byte-for-byte
            // across iverilog and Verilator.
            wire [31:0] lfsr_next = lfsr_q ^ (lfsr_q << 13) ^ (lfsr_q >> 17) ^ (lfsr_q << 5);

            always_ff @(posedge clk) begin
                if (rst) begin
                    state_q    <= S_IDLE;
                    lfsr_q     <= (seed_i == 32'b0) ? 32'hDEAD_BEEF : seed_i;
                    wait_cnt_q <= '0;
                    // addr_q/dat_q/sel_q/we_q/lock_q are latched data, not
                    // control state, so leaving them unreset looks
                    // harmless -- but lock_q specifically feeds
                    // wb_arbiter2's m1_lock_i input, read UNCONDITIONALLY
                    // by its idle_grant ternary even before this shim's
                    // side has ever issued a request. Left X, that X
                    // poisons idle_grant/grant/cyc_o for BOTH masters, not
                    // just this one -- including the other master, whose
                    // own real request would otherwise resolve it, a
                    // circular deadlock caught by an actual run showing
                    // cyc_o/addr_o/grant stuck at X forever, not by
                    // inspection.
                    addr_q <= '0; dat_q <= '0; sel_q <= '0; we_q <= 1'b0; lock_q <= 1'b0;
                end else begin
                    unique case (state_q)
                        S_IDLE: begin
                            if (up_cyc_i && up_stb_i) begin
                                addr_q <= up_addr_i;
                                dat_q  <= up_dat_i;
                                sel_q  <= up_sel_i;
                                we_q   <= up_we_i;
                                lock_q <= up_lock_i;
                                lfsr_q <= lfsr_next;
                                if (lfsr_next[CW-1:0] == '0) begin
                                    state_q <= S_REQ;
                                end else begin
                                    wait_cnt_q <= lfsr_next[CW-1:0];
                                    state_q    <= S_WAIT;
                                end
                            end
                        end
                        S_WAIT: begin
                            if (wait_cnt_q == 1) begin
                                state_q <= S_REQ;
                            end else begin
                                wait_cnt_q <= wait_cnt_q - 1'b1;
                            end
                        end
                        S_REQ: begin
                            if (dn_ack_i || dn_err_i) begin
                                state_q <= S_IDLE;
                            end
                        end
                        default: state_q <= S_IDLE;
                    endcase
                end
            end

            assign dn_addr_o = addr_q;
            assign dn_dat_o  = dat_q;
            assign dn_sel_o  = sel_q;
            assign dn_we_o   = we_q;
            assign dn_lock_o = lock_q;
            assign dn_cyc_o  = (state_q == S_REQ);
            assign dn_stb_o  = (state_q == S_REQ);
            assign up_dat_o  = dn_dat_i;
            assign up_ack_o  = (state_q == S_REQ) && dn_ack_i;
            assign up_err_o  = (state_q == S_REQ) && dn_err_i;
        end
    endgenerate
endmodule
