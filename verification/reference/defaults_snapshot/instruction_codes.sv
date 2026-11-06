// SPDX-License-Identifier: MIT

/*
 * Instruction codes for micro-architecture.
 *
 * We need a way to convey the decoded instruction from the decoder to the
 * executor in order to execute the appropriate operation on the next clock
 * cycle.
 *
 * Thus, we will define codes here for each instruction.
 */


/* Width of the codes. */
`define INSTR_CODE_SIZE 7

/* Code for signifying invalid instruction. */
`define INSTR_CODE_INVALID 000000


/* ------------------------------------------------------------------------- */


/* Upper immediate instructions. */

`define INSTR_CODE_LUI      000001
`define INSTR_CODE_AUIPC    000010


/* ------------------------------------------------------------------------- */


/* Jump instructions. */

`define INSTR_CODE_JAL  000011
`define INSTR_CODE_JALR 000100


/* ------------------------------------------------------------------------- */


/* Branch instructions. */

`define INSTR_CODE_BEQ  000101
`define INSTR_CODE_BNE  000110
`define INSTR_CODE_BLT  000111
`define INSTR_CODE_BGE  001000
`define INSTR_CODE_BLTU 001001
`define INSTR_CODE_BGEU 001010


/* ------------------------------------------------------------------------- */


/* Load instructions. */

`define INSTR_CODE_LB   001011
`define INSTR_CODE_LH   001100
`define INSTR_CODE_LW   001101
`define INSTR_CODE_LBU  001110
`define INSTR_CODE_LHU  001111


/* ------------------------------------------------------------------------- */


/* Store instructions. */

`define INSTR_CODE_SB   010000
`define INSTR_CODE_SH   010001
`define INSTR_CODE_SW   010010


/* ------------------------------------------------------------------------- */


/* ALU instructions. */

`define INSTR_CODE_ADDI     010011
`define INSTR_CODE_ADD      010100

`define INSTR_CODE_SUB      010101

`define INSTR_CODE_SLTI     010110
`define INSTR_CODE_SLT      010111

`define INSTR_CODE_SLTIU    011000
`define INSTR_CODE_SLTU     011001

`define INSTR_CODE_XORI     011010
`define INSTR_CODE_XOR      011011

`define INSTR_CODE_ORI      011100
`define INSTR_CODE_OR       011101

`define INSTR_CODE_ANDI     011110
`define INSTR_CODE_AND      011111

`define INSTR_CODE_SLLI     100000
`define INSTR_CODE_SLL      100001

`define INSTR_CODE_SRLI     100010
`define INSTR_CODE_SRL      100011

`define INSTR_CODE_SRAI     100100
`define INSTR_CODE_SRA      100101


/* ------------------------------------------------------------------------- */


/* Control instructions. */

`define INSTR_CODE_FENCE    100110
`define INSTR_CODE_ECALL    100111
`define INSTR_CODE_EBREAK   101000


/* ------------------------------------------------------------------------- */


/* RV64I-only instructions. */

`define INSTR_CODE_LWU      101001
`define INSTR_CODE_LD       101010
`define INSTR_CODE_SD       101011

`define INSTR_CODE_ADDIW    101100
`define INSTR_CODE_SLLIW    101101
`define INSTR_CODE_SRLIW    101110
`define INSTR_CODE_SRAIW    101111

`define INSTR_CODE_ADDW     110000
`define INSTR_CODE_SUBW     110001
`define INSTR_CODE_SLLW     110010
`define INSTR_CODE_SRLW     110011
`define INSTR_CODE_SRAW     110100


/* ------------------------------------------------------------------------- */


/* Zicsr (CSR) instructions. */

`define INSTR_CODE_CSRRW    110101   // 53
`define INSTR_CODE_CSRRS    110110   // 54
`define INSTR_CODE_CSRRC    110111   // 55
`define INSTR_CODE_CSRRWI   111000   // 56
`define INSTR_CODE_CSRRSI   111001   // 57
`define INSTR_CODE_CSRRCI   111010   // 58


/* ------------------------------------------------------------------------- */


/* M extension (integer multiply/divide) instructions. */

`define INSTR_CODE_MUL      0111011   // 59
`define INSTR_CODE_MULH     0111100   // 60
`define INSTR_CODE_MULHSU   0111101   // 61
`define INSTR_CODE_MULHU    0111110   // 62
`define INSTR_CODE_MULW     0111111   // 63

`define INSTR_CODE_DIV      1000000   // 64
`define INSTR_CODE_DIVU     1000001   // 65
`define INSTR_CODE_REM      1000010   // 66
`define INSTR_CODE_REMU     1000011   // 67

`define INSTR_CODE_DIVW     1000100   // 68
`define INSTR_CODE_DIVUW    1000101   // 69
`define INSTR_CODE_REMW     1000110   // 70
`define INSTR_CODE_REMUW    1000111   // 71

`define INSTR_CODE_MRET         1001000   // 72
`define INSTR_CODE_SRET         1001001   // 73
`define INSTR_CODE_WFI          1001010   // 74
`define INSTR_CODE_SFENCE_VMA   1001011   // 75

/* A extension (atomics) instructions. */

`define INSTR_CODE_LR_W         1001100   // 76
`define INSTR_CODE_LR_D         1001101   // 77
`define INSTR_CODE_SC_W         1001110   // 78
`define INSTR_CODE_SC_D         1001111   // 79

`define INSTR_CODE_AMOSWAP_W    1010000   // 80
`define INSTR_CODE_AMOSWAP_D    1010001   // 81
`define INSTR_CODE_AMOADD_W     1010010   // 82
`define INSTR_CODE_AMOADD_D     1010011   // 83
`define INSTR_CODE_AMOXOR_W     1010100   // 84
`define INSTR_CODE_AMOXOR_D     1010101   // 85
`define INSTR_CODE_AMOOR_W      1010110   // 86
`define INSTR_CODE_AMOOR_D      1010111   // 87
`define INSTR_CODE_AMOAND_W     1011000   // 88
`define INSTR_CODE_AMOAND_D     1011001   // 89
`define INSTR_CODE_AMOMIN_W     1011010   // 90
`define INSTR_CODE_AMOMIN_D     1011011   // 91
`define INSTR_CODE_AMOMAX_W     1011100   // 92
`define INSTR_CODE_AMOMAX_D     1011101   // 93
`define INSTR_CODE_AMOMINU_W    1011110   // 94
`define INSTR_CODE_AMOMINU_D    1011111   // 95
`define INSTR_CODE_AMOMAXU_W    1100000   // 96
`define INSTR_CODE_AMOMAXU_D    1100001   // 97


/* ------------------------------------------------------------------------- */


/* Zifencei. */

`define INSTR_CODE_FENCE_I      1100010   // 98


/* ------------------------------------------------------------------------- */


/* End of file. */
