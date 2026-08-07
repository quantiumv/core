// SPDX-License-Identifier: MIT

/*
 * Instruction and their masks for all instructions.
 *
 * The instructions assume other things in between as masked to 0.
 *
 * It would be helpful to open page 130 of the RISC-V spec.
 */

/* ------------------------------------------------------------------------- */


/* Upper immediate instructions. */

`define INSTR_LUI           32'b0110111
`define INSTR_MASK_LUI      32'b1111111

`define INSTR_AUIPC         32'b0010111
`define INSTR_MASK_AUIPC    32'b1111111


/* ------------------------------------------------------------------------- */


/* Jump instructions. */

`define INSTR_JAL       32'b1101111
`define INSTR_MASK_JAL  32'b1111111

`define INSTR_JALR      {17'b0, 3'b000, 5'b0, 7'b1100111}
`define INSTR_MASK_JALR {17'b0, 3'b111, 5'b0, 7'b1111111}


/* ------------------------------------------------------------------------- */


/* Branch instructions. */

`define BRANCH_INSTR_CREATE(funct3) {17'b0, funct3, 5'b0, 7'b1100011}
`define BRANCH_INSTRS_MASK          {17'b0, 3'b111, 5'b0, 7'b1111111}


`define INSTR_BEQ       `BRANCH_INSTR_CREATE(3'b000)
`define INSTR_MASK_BEQ  `BRANCH_INSTRS_MASK

`define INSTR_BNE       `BRANCH_INSTR_CREATE(3'b001)
`define INSTR_MASK_BNE  `BRANCH_INSTRS_MASK

`define INSTR_BLT       `BRANCH_INSTR_CREATE(3'b100)
`define INSTR_MASK_BLT  `BRANCH_INSTRS_MASK

`define INSTR_BGE       `BRANCH_INSTR_CREATE(3'b101)
`define INSTR_MASK_BGE  `BRANCH_INSTRS_MASK

`define INSTR_BLTU      `BRANCH_INSTR_CREATE(3'b110)
`define INSTR_MASK_BLTU `BRANCH_INSTRS_MASK

`define INSTR_BGEU      `BRANCH_INSTR_CREATE(3'b111)
`define INSTR_MASK_BGEU `BRANCH_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/* Load instructions. */

`define LOAD_INSTR_CREATE(funct3)   {17'b0, funct3, 5'b0, 7'b0000011}
`define LOAD_INSTRS_MASK            {17'b0, 3'b111, 5'b0, 7'b1111111}


`define INSTR_LB        `LOAD_INSTR_CREATE(3'b000)
`define INSTR_MASK_LB   `LOAD_INSTRS_MASK

`define INSTR_LH        `LOAD_INSTR_CREATE(3'b001)
`define INSTR_MASK_LH   `LOAD_INSTRS_MASK

`define INSTR_LW        `LOAD_INSTR_CREATE(3'b010)
`define INSTR_MASK_LW   `LOAD_INSTRS_MASK

`define INSTR_LBU       `LOAD_INSTR_CREATE(3'b100)
`define INSTR_MASK_LBU  `LOAD_INSTRS_MASK

`define INSTR_LHU       `LOAD_INSTR_CREATE(3'b101)
`define INSTR_MASK_LHU  `LOAD_INSTRS_MASK

/* RV64I: 32-bit load, zero-extended (LW sign-extends; this doesn't). */
`define INSTR_LWU       `LOAD_INSTR_CREATE(3'b110)
`define INSTR_MASK_LWU  `LOAD_INSTRS_MASK

/* RV64I: full 64-bit (doubleword) load. */
`define INSTR_LD        `LOAD_INSTR_CREATE(3'b011)
`define INSTR_MASK_LD   `LOAD_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/* Store instructions. */

`define STORE_INSTR_CREATE(funct3)  {17'b0, funct3, 5'b0, 7'b0100011}
`define STORE_INSTRS_MASK           {17'b0, 3'b111, 5'b0, 7'b1111111}


`define INSTR_SB        `STORE_INSTR_CREATE(3'b000)
`define INSTR_MASK_SB   `STORE_INSTRS_MASK

`define INSTR_SH        `STORE_INSTR_CREATE(3'b001)
`define INSTR_MASK_SH   `STORE_INSTRS_MASK

`define INSTR_SW        `STORE_INSTR_CREATE(3'b010)
`define INSTR_MASK_SW   `STORE_INSTRS_MASK

/* RV64I: full 64-bit (doubleword) store. */
`define INSTR_SD        `STORE_INSTR_CREATE(3'b011)
`define INSTR_MASK_SD   `STORE_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/* Immediate ALU instructions. */


/* Non-shift instructions. */

`define IMM_AL_INSTR_CREATE(funct3) {17'b0, funct3, 5'b0, 7'b0010011}
`define IMM_AL_INSTRS_MASK          {17'b0, 3'b111, 5'b0, 7'b1111111}

`define INSTR_ADDI          `IMM_AL_INSTR_CREATE(3'b000)
`define INSTR_MASK_ADDI     `IMM_AL_INSTRS_MASK

`define INSTR_SLTI          `IMM_AL_INSTR_CREATE(3'b010)
`define INSTR_MASK_SLTI     `IMM_AL_INSTRS_MASK

`define INSTR_SLTIU         `IMM_AL_INSTR_CREATE(3'b011)
`define INSTR_MASK_SLTIU    `IMM_AL_INSTRS_MASK

`define INSTR_XORI          `IMM_AL_INSTR_CREATE(3'b100)
`define INSTR_MASK_XORI     `IMM_AL_INSTRS_MASK

`define INSTR_ORI           `IMM_AL_INSTR_CREATE(3'b110)
`define INSTR_MASK_ORI      `IMM_AL_INSTRS_MASK

`define INSTR_ANDI          `IMM_AL_INSTR_CREATE(3'b111)
`define INSTR_MASK_ANDI     `IMM_AL_INSTRS_MASK


/* Shift instructions. */

`define IMM_SHIFT_INSTR_CREATE(bit30, funct3) \
                               {1'b0, bit30, 15'b0, funct3, 5'b0, 7'b0010011}
/*
 * RV64I widens the shift amount from 5 to 6 bits (log2(64) instead of
 * log2(32)) -- bit 25, which used to be a fixed part of a 7-bit funct7,
 * becomes shamt's top bit instead. So only funct6 (bits 31:26, 6 bits) is
 * checked as a fixed pattern now; bit 25 must be a don't-care alongside
 * the rest of the shamt field, not forced to 0 -- otherwise any shift
 * amount of 32 or more (which sets bit 25/shamt[5]) would fail to match
 * SLLI/SRLI/SRAI at all. IMM_SHIFT_INSTR_CREATE itself is unchanged: its
 * "15'b0" block already covers bit 25 with a 0 that's now simply ignored
 * (mask=0 there) rather than enforced.
 */
`define IMM_SHIFT_INSTRS_MASK   {6'b111111, 11'b0, 3'b111, 5'b0, 7'b1111111}

`define INSTR_SLLI      `IMM_SHIFT_INSTR_CREATE(1'b0, 3'b001)
`define INSTR_MASK_SLLI `IMM_SHIFT_INSTRS_MASK

`define INSTR_SRLI      `IMM_SHIFT_INSTR_CREATE(1'b0, 3'b101)
`define INSTR_MASK_SRLI `IMM_SHIFT_INSTRS_MASK

`define INSTR_SRAI      `IMM_SHIFT_INSTR_CREATE(1'b1, 3'b101)
`define INSTR_MASK_SRAI `IMM_SHIFT_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/*
 * RV64I word-width immediate instructions (opcode 0011011): ADDIW is a
 * plain I-type op, identical in shape to the IMM_AL family above just at
 * a different opcode. SLLIW/SRLIW/SRAIW keep a 5-bit shamt (word-shifts
 * are always 32-bit, regardless of WORD_SIZE) so, unlike the base shifts
 * above, their funct7 stays a full 7 fixed bits -- same shape as the
 * ORIGINAL (RV32I) IMM_SHIFT_INSTR_CREATE, just re-targeted to this
 * opcode.
 */

`define IMM_AL32_INSTR_CREATE(funct3) {17'b0, funct3, 5'b0, 7'b0011011}
`define IMM_AL32_INSTRS_MASK          {17'b0, 3'b111, 5'b0, 7'b1111111}

`define INSTR_ADDIW         `IMM_AL32_INSTR_CREATE(3'b000)
`define INSTR_MASK_ADDIW    `IMM_AL32_INSTRS_MASK


`define IMM_SHIFT32_INSTR_CREATE(bit30, funct3) \
                               {1'b0, bit30, 15'b0, funct3, 5'b0, 7'b0011011}
`define IMM_SHIFT32_INSTRS_MASK   {7'b1111111, 10'b0, 3'b111, 5'b0, 7'b1111111}

`define INSTR_SLLIW      `IMM_SHIFT32_INSTR_CREATE(1'b0, 3'b001)
`define INSTR_MASK_SLLIW `IMM_SHIFT32_INSTRS_MASK

`define INSTR_SRLIW      `IMM_SHIFT32_INSTR_CREATE(1'b0, 3'b101)
`define INSTR_MASK_SRLIW `IMM_SHIFT32_INSTRS_MASK

`define INSTR_SRAIW      `IMM_SHIFT32_INSTR_CREATE(1'b1, 3'b101)
`define INSTR_MASK_SRAIW `IMM_SHIFT32_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/* Non-immediate (3 register operands) ALU instructions. */

`define ALU_INSTR_CREATE(bit30, funct3) \
                           {1'b0, bit30, 15'b0, funct3, 5'b0, 7'b0110011}
`define ALU_INSTRS_MASK     {7'b1111111, 10'b0, 3'b111, 5'b0, 7'b1111111}


`define INSTR_ADD       `ALU_INSTR_CREATE(1'b0, 3'b000)
`define INSTR_MASK_ADD  `ALU_INSTRS_MASK

`define INSTR_SUB       `ALU_INSTR_CREATE(1'b1, 3'b000)
`define INSTR_MASK_SUB  `ALU_INSTRS_MASK

`define INSTR_SLL       `ALU_INSTR_CREATE(1'b0, 3'b001)
`define INSTR_MASK_SLL  `ALU_INSTRS_MASK

`define INSTR_SLT       `ALU_INSTR_CREATE(1'b0, 3'b010)
`define INSTR_MASK_SLT  `ALU_INSTRS_MASK

`define INSTR_SLTU      `ALU_INSTR_CREATE(1'b0, 3'b011)
`define INSTR_MASK_SLTU `ALU_INSTRS_MASK

`define INSTR_XOR       `ALU_INSTR_CREATE(1'b0, 3'b100)
`define INSTR_MASK_XOR  `ALU_INSTRS_MASK

`define INSTR_SRL       `ALU_INSTR_CREATE(1'b0, 3'b101)
`define INSTR_MASK_SRL  `ALU_INSTRS_MASK

`define INSTR_SRA       `ALU_INSTR_CREATE(1'b1, 3'b101)
`define INSTR_MASK_SRA  `ALU_INSTRS_MASK

`define INSTR_OR        `ALU_INSTR_CREATE(1'b0, 3'b110)
`define INSTR_MASK_OR   `ALU_INSTRS_MASK

`define INSTR_AND       `ALU_INSTR_CREATE(1'b0, 3'b111)
`define INSTR_MASK_AND  `ALU_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/*
 * RV64I word-width register-register instructions (opcode 0111011),
 * keyed on {bit30, funct3} exactly like ALU_INSTR_CREATE above, just at a
 * different opcode. Only 5 of the 8 combinations base ALU_INSTR_CREATE
 * supports are defined by the ISA here (no word-width OR/AND/XOR/SLT/
 * SLTU -- bitwise and compare ops are identical whether you consider the
 * upper 32 bits or not, so RV64I doesn't define separate "W" forms for
 * them).
 */

`define ALU32_INSTR_CREATE(bit30, funct3) \
                           {1'b0, bit30, 15'b0, funct3, 5'b0, 7'b0111011}
`define ALU32_INSTRS_MASK     {7'b1111111, 10'b0, 3'b111, 5'b0, 7'b1111111}

`define INSTR_ADDW       `ALU32_INSTR_CREATE(1'b0, 3'b000)
`define INSTR_MASK_ADDW  `ALU32_INSTRS_MASK

`define INSTR_SUBW       `ALU32_INSTR_CREATE(1'b1, 3'b000)
`define INSTR_MASK_SUBW  `ALU32_INSTRS_MASK

`define INSTR_SLLW       `ALU32_INSTR_CREATE(1'b0, 3'b001)
`define INSTR_MASK_SLLW  `ALU32_INSTRS_MASK

`define INSTR_SRLW       `ALU32_INSTR_CREATE(1'b0, 3'b101)
`define INSTR_MASK_SRLW  `ALU32_INSTRS_MASK

`define INSTR_SRAW       `ALU32_INSTR_CREATE(1'b1, 3'b101)
`define INSTR_MASK_SRAW  `ALU32_INSTRS_MASK


/* ------------------------------------------------------------------------- */


`define INSTR_FENCE         {17'b0, 3'b000, 5'b0, 7'b0001111}
`define INSTR_MASK_FENCE    {17'b0, 3'b111, 5'b0, 7'b0001111}


/* ------------------------------------------------------------------------- */


/* Environment instructions. */

`define ENV_INSTR_CREATE(bit20) {11'b0, bit20, 13'b0, 7'b1110011}
`define ENV_INSTRS_MASK         32'hFFFFFFFF


`define INSTR_ECALL         `ENV_INSTR_CREATE(1'b0)
`define INSTR_MASK_ECALL    `ENV_INSTRS_MASK

`define INSTR_EBREAK        `ENV_INSTR_CREATE(1'b1)
`define INSTR_MASK_EBREAK   `ENV_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/*
 * Zicsr (CSR) instructions. Same opcode (SYSTEM, 7'b1110011) as ECALL/
 * EBREAK above, disambiguated by funct3 -- all 6 Zicsr funct3 values are
 * nonzero, while ECALL/EBREAK's own mask (ENV_INSTRS_MASK, a full exact
 * match) forces funct3=000, so neither family can ever collide with the
 * other.
 */

`define CSR_INSTR_CREATE(funct3)   {17'b0, funct3, 5'b0, 7'b1110011}
`define CSR_INSTRS_MASK            {17'b0, 3'b111, 5'b0, 7'b1111111}

`define INSTR_CSRRW      `CSR_INSTR_CREATE(3'b001)
`define INSTR_MASK_CSRRW `CSR_INSTRS_MASK

`define INSTR_CSRRS      `CSR_INSTR_CREATE(3'b010)
`define INSTR_MASK_CSRRS `CSR_INSTRS_MASK

`define INSTR_CSRRC      `CSR_INSTR_CREATE(3'b011)
`define INSTR_MASK_CSRRC `CSR_INSTRS_MASK

`define INSTR_CSRRWI      `CSR_INSTR_CREATE(3'b101)
`define INSTR_MASK_CSRRWI `CSR_INSTRS_MASK

`define INSTR_CSRRSI      `CSR_INSTR_CREATE(3'b110)
`define INSTR_MASK_CSRRSI `CSR_INSTRS_MASK

`define INSTR_CSRRCI      `CSR_INSTR_CREATE(3'b111)
`define INSTR_MASK_CSRRCI `CSR_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/*
 * M extension (integer multiply/divide). Same opcodes as the base ALU
 * reg-reg ops (0110011) and the RV64I word-width family (0111011) above,
 * disambiguated by funct7 = 0000001 -- ALU_INSTRS_MASK/ALU32_INSTRS_MASK
 * already assert all 7 funct7 bits (their leading 7'b1111111 covers bits
 * [31:25], the whole field), so they're reused verbatim here; only a new
 * *_INSTR_CREATE is needed, since ALU_INSTR_CREATE/ALU32_INSTR_CREATE only
 * parameterize funct7 bit 30 and hardcode the rest to values that can only
 * ever produce 0000000 or 0100000 -- structurally incapable of 0000001.
 */

`define MUL_INSTR_CREATE(funct3)     {7'b0000001, 10'b0, funct3, 5'b0, 7'b0110011}
`define MUL32_INSTR_CREATE(funct3)   {7'b0000001, 10'b0, funct3, 5'b0, 7'b0111011}

`define INSTR_MUL         `MUL_INSTR_CREATE(3'b000)
`define INSTR_MASK_MUL    `ALU_INSTRS_MASK

`define INSTR_MULH        `MUL_INSTR_CREATE(3'b001)
`define INSTR_MASK_MULH   `ALU_INSTRS_MASK

`define INSTR_MULHSU      `MUL_INSTR_CREATE(3'b010)
`define INSTR_MASK_MULHSU `ALU_INSTRS_MASK

`define INSTR_MULHU       `MUL_INSTR_CREATE(3'b011)
`define INSTR_MASK_MULHU  `ALU_INSTRS_MASK

`define INSTR_DIV         `MUL_INSTR_CREATE(3'b100)
`define INSTR_MASK_DIV    `ALU_INSTRS_MASK

`define INSTR_DIVU        `MUL_INSTR_CREATE(3'b101)
`define INSTR_MASK_DIVU   `ALU_INSTRS_MASK

`define INSTR_REM         `MUL_INSTR_CREATE(3'b110)
`define INSTR_MASK_REM    `ALU_INSTRS_MASK

`define INSTR_REMU        `MUL_INSTR_CREATE(3'b111)
`define INSTR_MASK_REMU   `ALU_INSTRS_MASK

`define INSTR_MULW        `MUL32_INSTR_CREATE(3'b000)
`define INSTR_MASK_MULW   `ALU32_INSTRS_MASK

`define INSTR_DIVW        `MUL32_INSTR_CREATE(3'b100)
`define INSTR_MASK_DIVW   `ALU32_INSTRS_MASK

`define INSTR_DIVUW       `MUL32_INSTR_CREATE(3'b101)
`define INSTR_MASK_DIVUW  `ALU32_INSTRS_MASK

`define INSTR_REMW        `MUL32_INSTR_CREATE(3'b110)
`define INSTR_MASK_REMW   `ALU32_INSTRS_MASK

`define INSTR_REMUW       `MUL32_INSTR_CREATE(3'b111)
`define INSTR_MASK_REMUW  `ALU32_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/* End of file. */
