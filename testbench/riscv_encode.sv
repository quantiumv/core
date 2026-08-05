// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Small helper functions for hand-assembling RV64I instruction encodings
 * directly inside a testbench, without depending on the
 * riscv64-unknown-elf toolchain -- decouples RTL verification from that
 * toolchain's availability, and keeps the small, per-feature testbenches
 * in this milestone fast to write and iterate on.
 *
 * Each function takes named fields (never raw hex) and returns the
 * assembled 32-bit instruction word. Bit layouts here were checked
 * directly against decoder.sv's field-extraction code (imm_s/imm_b/
 * imm_u/imm_j, etc.), not just against the ISA spec, so an encoder/
 * decoder mismatch would show up as a wrong-looking test result rather
 * than silently canceling out.
 *
 * Immediates are accepted as plain `int` (32-bit signed) except encode_u,
 * where the field is inherently unshifted/unsigned at the encoding level
 * (see its own comment) -- callers write ordinary signed literals (e.g.
 * -5), and each function extracts exactly the bits it needs.
 */

function automatic logic [31:0] encode_r(
    input logic [6:0] funct7, input logic [4:0] rs2, input logic [4:0] rs1,
    input logic [2:0] funct3, input logic [4:0] rd, input logic [6:0] opcode
);
    return {funct7, rs2, rs1, funct3, rd, opcode};
endfunction

function automatic logic [31:0] encode_i(
    input int imm, input logic [4:0] rs1, input logic [2:0] funct3,
    input logic [4:0] rd, input logic [6:0] opcode
);
    return {imm[11:0], rs1, funct3, rd, opcode};
endfunction

/*
 * Thin wrapper around encode_i -- its existing bit layout already matches
 * all 6 CSR instructions exactly (CSR address -> imm field, rs1/uimm ->
 * rs1 field), so this exists purely for call-site readability: takes
 * csr_addr as an unsigned 12-bit field (a CSR address is never signed)
 * instead of encode_i's signed int.
 */
function automatic logic [31:0] encode_csr(
    input logic [11:0] csr_addr, input logic [4:0] rs1_or_uimm,
    input logic [2:0] funct3, input logic [4:0] rd, input logic [6:0] opcode
);
    return encode_i(int'(csr_addr), rs1_or_uimm, funct3, rd, opcode);
endfunction

/*
 * Shift-immediate, RV64I base shifts (SLLI/SRLI/SRAI): 6-bit shamt,
 * 6-bit funct6 -- bit 25, which used to be funct7's LSB under RV32I, is
 * now shamt's top bit (see instructions_and_masks.sv's IMM_SHIFT fix).
 * Distinct from encode_shift32w below -- mixing these two up produces a
 * validly-formed but WRONG instruction, not a compile error, so keep
 * them separate rather than one function with an ambiguous "does bit 25
 * mean funct7 or shamt" parameter.
 */
function automatic logic [31:0] encode_shift64(
    input logic [5:0] funct6, input logic [5:0] shamt, input logic [4:0] rs1,
    input logic [2:0] funct3, input logic [4:0] rd, input logic [6:0] opcode
);
    return {funct6, shamt, rs1, funct3, rd, opcode};
endfunction

/*
 * Shift-immediate, RV64I word shifts (SLLIW/SRLIW/SRAIW): these stay at
 * a 5-bit shamt (word-shifts are always 32-bit) with a full 7-bit
 * funct7, same shape as the ORIGINAL RV32I base-shift encoding, just at
 * a different opcode.
 */
function automatic logic [31:0] encode_shift32w(
    input logic [6:0] funct7, input logic [4:0] shamt, input logic [4:0] rs1,
    input logic [2:0] funct3, input logic [4:0] rd, input logic [6:0] opcode
);
    return {funct7, shamt, rs1, funct3, rd, opcode};
endfunction

function automatic logic [31:0] encode_s(
    input int imm, input logic [4:0] rs2, input logic [4:0] rs1,
    input logic [2:0] funct3, input logic [6:0] opcode
);
    return {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
endfunction

/*
 * imm is the actual branch offset in bytes -- must be even (bit 0 is
 * architecturally always 0 and isn't stored), matching how a real
 * assembler takes a branch target label, not a pre-shifted encoding.
 */
function automatic logic [31:0] encode_b(
    input int imm, input logic [4:0] rs2, input logic [4:0] rs1,
    input logic [2:0] funct3, input logic [6:0] opcode
);
    return {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode};
endfunction

/*
 * imm is the raw 20-bit field that lands directly in bits [31:12] --
 * i.e. NOT pre-shifted-then-truncated, the same convention real
 * assembly's `lui`/`auipc` immediate uses. Turning this into an actual
 * address-sized value (shifting into place, sign-extending) is
 * decoder.sv's job (imm_u_sext), not this function's.
 */
function automatic logic [31:0] encode_u(
    input logic [19:0] imm, input logic [4:0] rd, input logic [6:0] opcode
);
    return {imm, rd, opcode};
endfunction

/* imm is the actual jump offset in bytes -- must be even, same reasoning as encode_b. */
function automatic logic [31:0] encode_j(
    input int imm, input logic [4:0] rd, input logic [6:0] opcode
);
    return {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode};
endfunction


/* ------------------------------------------------------------------------- */


/* Opcodes, for readability at call sites -- avoids repeating raw 7-bit literals. */
`define OPC_LOAD      7'b0000011
`define OPC_OP_IMM    7'b0010011
`define OPC_STORE     7'b0100011
`define OPC_OP        7'b0110011
`define OPC_LUI       7'b0110111
`define OPC_OP_IMM_32 7'b0011011
`define OPC_OP_32     7'b0111011
`define OPC_AUIPC     7'b0010111
`define OPC_JAL       7'b1101111
`define OPC_JALR      7'b1100111
`define OPC_BRANCH    7'b1100011
`define OPC_SYSTEM    7'b1110011

/* SYSTEM-opcode funct3 encodings for the 6 Zicsr instructions, for readability at call sites. */
`define FUNCT3_CSRRW  3'b001
`define FUNCT3_CSRRS  3'b010
`define FUNCT3_CSRRC  3'b011
`define FUNCT3_CSRRWI 3'b101
`define FUNCT3_CSRRSI 3'b110
`define FUNCT3_CSRRCI 3'b111

/* CSR addresses backed by design/csr_file.sv, for readable call sites in the Zicsr testbenches. */
`define CSR_MISA      12'h301
`define CSR_MVENDORID 12'hF11
`define CSR_MARCHID   12'hF12
`define CSR_MIMPID    12'hF13
`define CSR_MHARTID   12'hF14
`define CSR_MSCRATCH  12'h340
`define CSR_MCYCLE    12'hB00
`define CSR_MINSTRET  12'hB02


/* ------------------------------------------------------------------------- */


/* End of file. */
