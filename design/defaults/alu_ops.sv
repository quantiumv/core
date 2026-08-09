// SPDX-License-Identifier: MIT

/* Define ALU op bits for internal microarchitecture. */


/* ------------------------------------------------------------------------- */


`define ALU_OPSIZE 5    /* 22 ops now (18 + MIN/MAX/MINU/MAXU); still fits 5 bits. */


/* ------------------------------------------------------------------------- */


/* Standard ISA instructions. */

`define ADD     5'b00000     /* Word addition, overflow ignored */
`define SUB     5'b00001     /* Word subtraction, overflow ignored */

`define OR      5'b00010     /* Bitwise OR */
`define AND     5'b00011     /* Bitwise AND */
`define XOR     5'b00100     /* Bitwise Exclusive OR */

`define SLT     5'b00101     /* Set less than (Y = A < B; signed A, B) */
`define SLTU    5'b00110     /* Set less than unsigned (unsigned A, B) */

`define SLL     5'b00111     /* Shift left (logical) */
`define SRL     5'b01000     /* Shift right (logical) */
`define SRA     5'b01001     /* Shift right (arithmetic) */


/* ------------------------------------------------------------------------- */


/* Custom instructions. */

`define NOT     5'b01010     /* Bitwise NOT / inversion */


/* ------------------------------------------------------------------------- */


/*
 * RV64I word ops (operate on the low 32 bits of the operands, shift amount
 * is always 5 bits regardless of WORD_SIZE, result is sign-extended back to
 * WORD_SIZE bits).
 *
 * These can NOT be synthesized by truncating SLL/SRL/SRA's 64-bit result:
 * unlike add/sub, a shift is not width-agnostic -- shifting a 64-bit operand
 * by a 6-bit amount and then truncating to 32 bits gives a different answer
 * than shifting a 32-bit operand by a 5-bit amount (bits enter/exit from the
 * wrong end once the shift amount's bit 5 differs, and bits above 31 that
 * shouldn't participate at all can leak into the low 32 via SLL). So these
 * get their own dedicated ops instead of reusing SLL/SRL/SRA.
 */

`define SLLW    5'b01011     /* Shift left word: (A[31:0] << B[4:0]), sign-extended */
`define SRLW    5'b01100     /* Shift right word logical: (A[31:0] >> B[4:0]), sign-extended */
`define SRAW    5'b01101     /* Shift right word arithmetic: (A[31:0] >>> B[4:0]), sign-extended */


/* ------------------------------------------------------------------------- */


/*
 * M extension: multiply. DIV/DIVU/REM/REMU (and their W variants) do NOT
 * get ops here -- they route through design/divider.sv instead, a separate
 * multi-cycle module, not the (purely combinational) ALU. MULW needs no
 * dedicated op either: a 32x32-truncated-to-32 product is bit-identical
 * regardless of what sits in the operands' upper 32 bits (multiplication
 * mod 2^32 is invariant to that), so MULW just reuses MUL and gets
 * truncated+resigned centrally in core.sv, the same way ADDW/SUBW reuse
 * ADD/SUB -- unlike SLLW/SRLW/SRAW above, which genuinely need their own
 * ops because a shift is NOT width-agnostic the same way.
 */

`define MUL     5'b01110   /* Low WORD_SIZE bits of A * B (signedness irrelevant to low bits) */
`define MULH    5'b01111   /* High WORD_SIZE bits of A * B, both signed */
`define MULHSU  5'b10000   /* High WORD_SIZE bits of A * B, A signed / B unsigned */
`define MULHU   5'b10001   /* High WORD_SIZE bits of A * B, both unsigned */


/* ------------------------------------------------------------------------- */


/*
 * A extension: AMOMIN/AMOMAX/AMOMINU/AMOMAXU value selection. These return
 * the WINNING OPERAND itself, not a 0/1 flag, so they can't be built from
 * SLT/SLTU the way a branch comparison can -- genuinely new ops.
 */

`define MIN     5'b10010   /* Signed minimum: A < B ? A : B */
`define MAX     5'b10011   /* Signed maximum: A < B ? B : A */
`define MINU    5'b10100   /* Unsigned minimum */
`define MAXU    5'b10101   /* Unsigned maximum */


/* ------------------------------------------------------------------------- */


/* End of file. */
