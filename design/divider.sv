// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: divider
 *
 * M extension: DIV/DIVU/REM/REMU (and, via core.sv's pre/post-extension
 * wrapper, DIVW/DIVUW/REMW/REMUW too -- see core.sv's own "M extension:
 * divide" section). The one genuinely new piece of hardware this milestone
 * adds: a multi-cycle, iterative divider, deliberately NOT combinational
 * like the rest of the ALU. core.sv's FSM has never had a variable-latency
 * non-memory instruction before this; see its own header/commit_now
 * comments for how `i_start`/`o_busy`/`o_done` hook into that.
 *
 * Simple 1-bit-per-cycle RESTORING division (not non-restoring, not a
 * higher radix) -- WORD_SIZE cycles for a real division, deliberately
 * prioritizing simplicity and every-intermediate-state-is-checkable
 * verifiability over cycle count. No synthesis flow exists for this
 * project yet, so there is no timing/area concern to trade against right
 * now; this can be revisited if/when that changes.
 *
 * Interface contract:
 *  i_start:  one-cycle pulse to begin a new division. Ignored while
 *            o_busy is already high (a caller that also gates i_start on
 *            !o_busy, as core.sv's does, never actually exercises this,
 *            but it's a real guard, not just documentation).
 *  i_signed: 1 for DIV/REM-family (and DIVW/REMW), 0 for DIVU/REMU-family
 *            (and DIVUW/REMUW). Selects magnitude-then-sign-correct
 *            handling internally; unsigned operands pass through as-is.
 *  o_busy:   high from the cycle after i_start until o_done.
 *  o_done:   one-cycle pulse the same cycle o_quotient/o_remainder become
 *            valid (this is also the correct cycle for a caller to latch
 *            them -- they're plain combinational reads of internal
 *            registers, not separately registered outputs, so they hold
 *            garbage/intermediate values while o_busy is high; nothing
 *            about that matters as long as a caller only reads them
 *            when/after o_done, exactly like core.sv's div_stall does).
 *
 * Division-by-zero and signed-overflow (dividend = most-negative,
 * divisor = -1) both need specific, non-trapping override results per
 * spec (see docs.riscv.org's M-extension page) -- but deliberately have
 * almost no special-case detection logic anywhere in this file -- both
 * fall out for free from plain two's-complement magnitude arithmetic,
 * with exactly one explicit exception (see the sign-correction comment
 * near o_quotient below):
 *
 *  - Divide by zero: subtracting a zero divisor_mag never succeeds
 *    (shifted_rem is never negative when nothing is ever subtracted from
 *    it), so every iteration takes the "quotient bit = 1" branch --
 *    after WORD_SIZE iterations, quot_q is all-1s (== 2^WORD_SIZE-1,
 *    exactly DIVU's required override, and reinterpreted signed == -1,
 *    exactly DIV's) REGARDLESS of what was loaded into it -- which is
 *    exactly why the quotient needs its one explicit exception: the
 *    general sign-correction step below would otherwise negate this
 *    fixed, sign-independent override whenever the dividend happened to
 *    be negative. rem_q, meanwhile, never has anything subtracted from
 *    it either, so it ends up holding exactly the shifted-in dividend
 *    bits unchanged -- exactly REM/REMU's required "dividend, unchanged"
 *    override, and this one genuinely needs no exception: "dividend
 *    unchanged" already IS "magnitude, then apply dividend's sign",
 *    exactly what the general sign-correction step does for every case.
 *  - Signed overflow (dividend = -2^63, divisor = -1): taking the
 *    magnitude of -2^63 in 64 bits is itself a two's-complement
 *    "overflow" that lands back on the same bit pattern (0x8000...0,
 *    since 2^63 has no positive 64-bit signed representation) -- but as
 *    an UNSIGNED magnitude for this algorithm, 0x8000...0 correctly
 *    represents 2^63, and 2^63 / 1 (divisor -1's magnitude) = 2^63
 *    remainder 0 unsigned, i.e. quot_q ends up 0x8000...0 again. Sign
 *    correction (dividend_neg XOR divisor_neg = 1 XOR 1 = 0, i.e. NOT
 *    negated) leaves it exactly there -- reinterpreted signed,
 *    0x8000...0 IS -2^63, exactly DIV's required "dividend itself"
 *    override, with remainder 0 exactly matching REM's. No exception
 *    needed here -- unlike divide-by-zero, this case's quotient DOES
 *    happen to want the normal XOR-sign rule applied (not-negated, and
 *    not-negated is exactly what a fixed-point 0x8000...0 needs to stay
 *    put).
 *
 * This is proven by design/divider_tb.sv's explicit divide-by-zero and
 * signed-overflow test cases, not just asserted here -- an earlier
 * version of this file assumed NEITHER case needed any exception at all,
 * which divider_tb.sv's -1/0 (signed) case disproved immediately.
 */
module divider (
    input  logic i_clk,
    input  logic i_rst,
    input  logic i_start,
    input  logic [(`WORD_SIZE - 1):0] i_dividend,
    input  logic [(`WORD_SIZE - 1):0] i_divisor,
    input  logic i_signed,

    output logic o_busy,
    output logic o_done,
    output logic [(`WORD_SIZE - 1):0] o_quotient,
    output logic [(`WORD_SIZE - 1):0] o_remainder
);

    localparam CNT_SIZE = `L2_WORD_SIZE + 1;   /* 7 bits for WORD_SIZE=64 -- must hold the value 64 itself. */

    logic busy_q;
    logic [(CNT_SIZE - 1):0] cycles_left_q;
    logic dividend_neg_q, divisor_neg_q;
    logic [(`WORD_SIZE - 1):0] divisor_mag_q;

    /*
     * {rem_q, quot_q} act as one combined shift register: quot_q starts
     * holding the (magnitude) dividend, and each cycle shifts its own MSB
     * into rem_q's LSB while a new quotient bit shifts into quot_q's own
     * now-vacated LSB -- the standard space-efficient way to do restoring
     * division without a separate, wider dividend-shift register. rem_q
     * itself only ever needs to STORE WORD_SIZE bits (the true remainder
     * value fits in that width after every valid step, by the restoring
     * algorithm's own invariant) -- the extra sign bit a trial subtraction
     * needs only exists transiently, in the wider shifted_rem/trial_diff
     * wires below, never in rem_q's own stored state.
     */
    logic [(`WORD_SIZE - 1):0] rem_q;
    logic [(`WORD_SIZE - 1):0] quot_q;

    assign o_busy = busy_q;

    logic [`WORD_SIZE:0] shifted_rem;
    logic [(`WORD_SIZE - 1):0] shifted_quot;
    assign shifted_rem  = {rem_q, quot_q[(`WORD_SIZE - 1)]};
    assign shifted_quot = {quot_q[(`WORD_SIZE - 2):0], 1'b0};

    logic [`WORD_SIZE:0] trial_diff;
    assign trial_diff = shifted_rem - {1'b0, divisor_mag_q};
    wire subtract_ok = !trial_diff[`WORD_SIZE];   /* sign bit of the (WORD_SIZE+1)-bit trial result */

    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            busy_q        <= 1'b0;
            cycles_left_q <= '0;
            o_done        <= 1'b0;
        end else begin
            o_done <= 1'b0;   /* default: a one-cycle pulse, overridden below on the completing cycle */

            if (i_start && !busy_q) begin
                /*
                 * Load cycle: take magnitudes (a no-op when !i_signed),
                 * zero the running remainder, seed the running quotient
                 * with the dividend magnitude (see the module header for
                 * why this doubles as the not-yet-shifted-in dividend
                 * bits), and start the WORD_SIZE-iteration countdown.
                 * The first real shift-subtract happens next cycle, not
                 * this one.
                 */
                dividend_neg_q <= i_signed && i_dividend[(`WORD_SIZE - 1)];
                divisor_neg_q  <= i_signed && i_divisor[(`WORD_SIZE - 1)];
                divisor_mag_q  <= (i_signed && i_divisor[(`WORD_SIZE - 1)])
                                   ? (~i_divisor + 1'b1) : i_divisor;
                quot_q         <= (i_signed && i_dividend[(`WORD_SIZE - 1)])
                                   ? (~i_dividend + 1'b1) : i_dividend;
                rem_q          <= '0;
                cycles_left_q  <= `WORD_SIZE;
                busy_q         <= 1'b1;
            end else if (busy_q) begin
                if (subtract_ok) begin
                    rem_q  <= trial_diff[(`WORD_SIZE - 1):0];
                    /*
                     * shifted_quot already IS the shifted value, with a
                     * placeholder 0 sitting in bit 0 from the unconditional
                     * shift above -- overwrite just that bit to 1 here.
                     * Taking shifted_quot[(WORD_SIZE-2):0] (as an earlier,
                     * buggy version of this file did) drops shifted_quot's
                     * OWN bit (WORD_SIZE-1) and re-shifts everything up one
                     * MORE position -- a real double-shift bug, caught by
                     * design/divider_tb.sv's 100/7 case (a division with a
                     * genuinely nonzero remainder; the bug happened to be
                     * invisible on exact-division cases like 12/3, where
                     * the corrupted position was never observed at 0).
                     */
                    quot_q <= {shifted_quot[(`WORD_SIZE - 1):1], 1'b1};
                end else begin
                    rem_q  <= shifted_rem[(`WORD_SIZE - 1):0];
                    quot_q <= shifted_quot;
                end
                cycles_left_q <= cycles_left_q - 1'b1;
                if (cycles_left_q == 1) begin
                    busy_q <= 1'b0;
                    o_done <= 1'b1;
                end
            end
        end
    end

    /*
     * Sign correction, applied combinationally to the final registered
     * rem_q/quot_q -- quotient's sign is the XOR of the two operands'
     * signs (negative iff exactly one was negative), remainder always
     * takes the dividend's sign ("rounds toward zero" semantics, matching
     * both the spec and SystemVerilog's own native signed / and % on
     * `logic signed` types). Both wires are !i_signed-safe: dividend_neg_q/
     * divisor_neg_q are unconditionally 0 whenever i_signed was 0 at
     * i_start time (see the load-cycle assignments above), so this
     * simplifies to a no-op negation for the unsigned families.
     *
     * Divide-by-zero's quotient is the ONE case that needs an explicit
     * exception here, not just "let the algorithm's natural magnitude
     * arithmetic fall out correctly" (see the module header's broader
     * claim -- this is the one place it needed a caveat, found by
     * divider_tb.sv's -1/0 case). REM's "dividend, unchanged" override
     * naturally IS "magnitude, then apply dividend's sign" -- exactly what
     * this file already does unconditionally, no exception needed. But
     * DIV's "-1, always" override is a FIXED constant that does NOT
     * follow the normal quotient-sign XOR rule: quot_q correctly ends up
     * all-1s regardless of what was loaded into it when divisor_mag_q is
     * 0 (nothing ever subtracts, so every iteration's quotient bit is
     * forced to 1 -- true regardless of dividend's magnitude or sign),
     * but then naively XOR-negating that all-1s pattern whenever the
     * dividend happened to be negative flips it to +1 -- wrong. Bypass
     * sign correction entirely for this one case; the un-negated all-1s
     * pattern IS already the correct answer for both DIV (reinterpreted
     * signed, all-1s == -1) and DIVU (== 2^WORD_SIZE-1) alike.
     */
    wire quotient_neg = dividend_neg_q ^ divisor_neg_q;
    assign o_quotient  = (divisor_mag_q == 0) ? {`WORD_SIZE{1'b1}} :
                          quotient_neg         ? (~quot_q + 1'b1)   : quot_q;
    assign o_remainder = dividend_neg_q ? (~rem_q + 1'b1) : rem_q;

endmodule: divider


/* ------------------------------------------------------------------------- */


/* End of file. */
