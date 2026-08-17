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
`define OPC_FENCE     7'b0001111

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

/*
 * U/S/M privilege-mode instructions -- MRET/SRET/WFI are each a single
 * fixed 32-bit pattern (no operand fields at all), so unlike every
 * encode_* function above there's nothing to assemble -- these are
 * plain literal-hex defines, not functions, matching
 * design/defaults/instructions_and_masks.sv's own INSTR_MRET/SRET/WFI
 * values exactly (independently re-verified by hand against the R-type
 * field layout, not copy-pasted).
 */
`define INSTR_HEX_MRET 32'h30200073
`define INSTR_HEX_SRET 32'h10200073
`define INSTR_HEX_WFI  32'h10500073

/* SFENCE.VMA: real rs1/rs2 operands, so this uses encode_r like any
 * ordinary R-type instruction (funct7=0001001, funct3=000, rd=0 always). */
`define FUNCT7_SFENCE_VMA 7'b0001001

/* U/S/M privilege-mode CSR addresses backed by design/csr_file.sv, for
 * readable call sites in testbench/core_priv_tb.sv. */
`define CSR_SSTATUS    12'h100
`define CSR_SIE        12'h104
`define CSR_STVEC      12'h105
`define CSR_SCOUNTEREN 12'h106
`define CSR_SSCRATCH   12'h140
`define CSR_SEPC       12'h141
`define CSR_SCAUSE     12'h142
`define CSR_STVAL      12'h143
`define CSR_SIP        12'h144
`define CSR_SATP       12'h180
`define CSR_MSTATUS    12'h300
`define CSR_MEDELEG    12'h302
`define CSR_MIDELEG    12'h303
`define CSR_MIE        12'h304
`define CSR_MTVEC      12'h305
`define CSR_MCOUNTEREN 12'h306
`define CSR_MEPC       12'h341
`define CSR_MCAUSE     12'h342
`define CSR_MTVAL      12'h343
`define CSR_MIP        12'h344

/*
 * A extension (atomics): R-type shaped, but funct7's role is split into
 * funct5[4:0]+aq+rl rather than one plain 7-bit field -- encode_r's
 * existing funct7 parameter already accepts any 7-bit value, including
 * this packing, so this exists purely for call-site readability (named
 * funct5/aq/rl fields instead of a hand-packed blob), same reason
 * encode_csr thinly wraps encode_i.
 */
function automatic logic [31:0] encode_amo(
    input logic [4:0] funct5, input logic aq, input logic rl,
    input logic [4:0] rs2, input logic [4:0] rs1,
    input logic [2:0] funct3, input logic [4:0] rd, input logic [6:0] opcode
);
    return encode_r({funct5, aq, rl}, rs2, rs1, funct3, rd, opcode);
endfunction

`define OPC_AMO         7'b0101111
`define FUNCT3_AMO_W    3'b010
`define FUNCT3_AMO_D    3'b011
`define FUNCT5_LR       5'h02
`define FUNCT5_SC       5'h03
`define FUNCT5_AMOSWAP  5'h01
`define FUNCT5_AMOADD   5'h00
`define FUNCT5_AMOXOR   5'h04
`define FUNCT5_AMOOR    5'h08
`define FUNCT5_AMOAND   5'h0C
`define FUNCT5_AMOMIN   5'h10
`define FUNCT5_AMOMAX   5'h14
`define FUNCT5_AMOMINU  5'h18
`define FUNCT5_AMOMAXU  5'h1C


/* ------------------------------------------------------------------------- */


/*
 * C extension (16-bit compressed instructions, RV64 Zca). Every encoder
 * below takes LOGICAL values (a real immediate/offset, a real register
 * index) and does its own bit-scramble internally -- deliberately NOT
 * shared code with design/c_expand.sv's own mk_r/mk_i/... helpers and
 * dispatch logic (a completely separate file, written independently
 * against the same RVC spec tables), so a bug shared between the two
 * would have to be a genuine shared misunderstanding of the spec, not a
 * copy-paste-shared mistake. This is the actual reason
 * testbench/core_c_ext_tb.sv (pillar 2) and
 * testbench/c_encode_crosscheck_tb.sv (pillar 3) have real, independent
 * verification value against c_expand.sv, not just a second copy of the
 * same formulas.
 *
 * Register-field convention (mirrors c_expand.sv's own header note):
 * CR-format fields and every CI-format destination register are full,
 * UNMAPPED 5-bit indices -- callers pass a plain logic[4:0]. CIW/CL/CS/CA
 * formats and the arithmetic/branch rows of CB use the compressed 3-bit
 * "popular register" convention (x8-x15) -- callers pass a plain
 * logic[2:0] (already relative to x8, i.e. 3'd0 == x8), using the _3
 * suffix on the parameter name below.
 */

/* ---- Quadrant 0 (op=00) ---- */

function automatic logic [15:0] encode_c_addi4spn(input logic [9:0] nzuimm, input logic [2:0] rd_3);
    return {3'b000, nzuimm[5:4], nzuimm[9:6], nzuimm[2], nzuimm[3], rd_3, 2'b00};
endfunction

function automatic logic [15:0] encode_c_lw(input logic [6:0] off, input logic [2:0] rs1_3, input logic [2:0] rd_3);
    return {3'b010, off[5:3], rs1_3, off[2], off[6], rd_3, 2'b00};
endfunction

function automatic logic [15:0] encode_c_ld(input logic [7:0] off, input logic [2:0] rs1_3, input logic [2:0] rd_3);
    return {3'b011, off[5:3], rs1_3, off[7:6], rd_3, 2'b00};
endfunction

function automatic logic [15:0] encode_c_sw(input logic [6:0] off, input logic [2:0] rs1_3, input logic [2:0] rs2_3);
    return {3'b110, off[5:3], rs1_3, off[2], off[6], rs2_3, 2'b00};
endfunction

function automatic logic [15:0] encode_c_sd(input logic [7:0] off, input logic [2:0] rs1_3, input logic [2:0] rs2_3);
    return {3'b111, off[5:3], rs1_3, off[7:6], rs2_3, 2'b00};
endfunction

/* ---- Quadrant 1 (op=01) ---- */

/* Generic plain-6-bit-signed-immediate CI shape: C.ADDI/C.ADDIW/C.LI.
 * rd_rs1 is a full 5-bit index (0 is a legal, spec-defined HINT for
 * C.ADDI/C.LI -- callers wanting C.LI pass rs1_field=x0 by construction,
 * see encode_c_li below). */
function automatic logic [15:0] encode_c_i_imm(input logic [2:0] funct3, input int imm, input logic [4:0] rd_rs1);
    return {funct3, imm[5], rd_rs1, imm[4:0], 2'b01};
endfunction

function automatic logic [15:0] encode_c_addi(input int imm, input logic [4:0] rd_rs1);
    return encode_c_i_imm(3'b000, imm, rd_rs1);
endfunction

function automatic logic [15:0] encode_c_addiw(input int imm, input logic [4:0] rd_rs1);
    return encode_c_i_imm(3'b001, imm, rd_rs1);
endfunction

function automatic logic [15:0] encode_c_li(input int imm, input logic [4:0] rd);
    return encode_c_i_imm(3'b010, imm, rd);
endfunction

function automatic logic [15:0] encode_c_addi16sp(input int nzimm);
    logic [9:0] u;
    u = nzimm[9:0];
    return {3'b011, u[9], 5'b00010, u[4], u[6], u[8:7], u[5], 2'b01};
endfunction

/* nzimm18 is the raw {bit17, bits16:12} 6-bit field (nzimm17 = sign bit)
 * -- NOT a pre-shifted 32-bit LUI value; matches how the spec itself
 * frames C.LUI's immediate, and how design/c_expand.sv's own o_illegal
 * check for it is phrased ("raw 6 bits all zero"). */
function automatic logic [15:0] encode_c_lui(input logic [5:0] nzimm6, input logic [4:0] rd);
    return {3'b011, nzimm6[5], rd, nzimm6[4:0], 2'b01};
endfunction

function automatic logic [15:0] encode_c_slli(input logic [5:0] shamt, input logic [4:0] rd);
    return {3'b000, shamt[5], rd, shamt[4:0], 2'b10};
endfunction

function automatic logic [15:0] encode_c_srli(input logic [5:0] shamt, input logic [2:0] rd_3);
    return {3'b100, shamt[5], 2'b00, rd_3, shamt[4:0], 2'b01};
endfunction

function automatic logic [15:0] encode_c_srai(input logic [5:0] shamt, input logic [2:0] rd_3);
    return {3'b100, shamt[5], 2'b01, rd_3, shamt[4:0], 2'b01};
endfunction

function automatic logic [15:0] encode_c_andi(input int imm, input logic [2:0] rd_3);
    return {3'b100, imm[5], 2'b10, rd_3, imm[4:0], 2'b01};
endfunction

/* CA format: reg-reg among the 8 popular registers. i12 selects
 * 32-bit-result (0, opcode OP) vs. RV64 *W-result (1, opcode OP-32);
 * funct2 then picks the specific op within each -- see the funct2
 * `define`s below. */
function automatic logic [15:0] encode_c_ca(input logic i12, input logic [1:0] funct2, input logic [2:0] rd_3, input logic [2:0] rs2_3);
    return {3'b100, i12, 2'b11, rd_3, funct2, rs2_3, 2'b01};
endfunction

function automatic logic [15:0] encode_c_j(input int offset);
    logic [11:0] t;
    t = offset[11:0];
    return {3'b101, t[11], t[4], t[9], t[8], t[10], t[6], t[7], t[3:1], t[5], 2'b01};
endfunction

function automatic logic [15:0] encode_c_beqz(input int offset, input logic [2:0] rs1_3);
    logic [8:0] o;
    o = offset[8:0];
    return {3'b110, o[8], o[4:3], rs1_3, o[7:6], o[2:1], o[5], 2'b01};
endfunction

function automatic logic [15:0] encode_c_bnez(input int offset, input logic [2:0] rs1_3);
    logic [8:0] o;
    o = offset[8:0];
    return {3'b111, o[8], o[4:3], rs1_3, o[7:6], o[2:1], o[5], 2'b01};
endfunction

/* ---- Quadrant 2 (op=10) ---- */

function automatic logic [15:0] encode_c_lwsp(input logic [7:0] off, input logic [4:0] rd);
    return {3'b010, off[5], rd, off[4:2], off[7:6], 2'b10};
endfunction

function automatic logic [15:0] encode_c_ldsp(input logic [8:0] off, input logic [4:0] rd);
    return {3'b011, off[5], rd, off[4:3], off[8:6], 2'b10};
endfunction

function automatic logic [15:0] encode_c_jr(input logic [4:0] rs1);
    return {4'b1000, rs1, 5'b00000, 2'b10};
endfunction

function automatic logic [15:0] encode_c_mv(input logic [4:0] rd, input logic [4:0] rs2);
    return {4'b1000, rd, rs2, 2'b10};
endfunction

function automatic logic [15:0] encode_c_jalr(input logic [4:0] rs1);
    return {4'b1001, rs1, 5'b00000, 2'b10};
endfunction

function automatic logic [15:0] encode_c_add(input logic [4:0] rd, input logic [4:0] rs2);
    return {4'b1001, rd, rs2, 2'b10};
endfunction

function automatic logic [15:0] encode_c_swsp(input logic [7:0] off, input logic [4:0] rs2);
    return {3'b110, off[5:2], off[7:6], rs2, 2'b10};
endfunction

function automatic logic [15:0] encode_c_sdsp(input logic [8:0] off, input logic [4:0] rs2);
    return {3'b111, off[5:3], off[8:6], rs2, 2'b10};
endfunction

`define INSTR_C_EBREAK  16'h9002
`define OPC_C0          2'b00
`define OPC_C1          2'b01
`define OPC_C2          2'b10
`define CA_FUNCT2_SUB   2'b00  /* also C.SUBW when encode_c_ca's i12=1 */
`define CA_FUNCT2_XOR   2'b01  /* also C.ADDW when encode_c_ca's i12=1 */
`define CA_FUNCT2_OR    2'b10
`define CA_FUNCT2_AND   2'b11


/* ------------------------------------------------------------------------- */


/* End of file. */
