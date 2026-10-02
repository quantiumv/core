// SPDX-License-Identifier: MIT

/*
 * qv_pkg -- shared types for the pipelined core (design/pipe/core_pipe.sv).
 *
 * Field names follow the pipelining plan's full uop_t/rob_entry_t/
 * fu_req_t/wb_t definitions wherever a field has meaning for the
 * instructions implemented so far, so later increments only ever ADD
 * fields here, never rename one already in use. Fields that only matter
 * to features not built yet (branches, loads/stores, CSR/system ops,
 * traps) are deliberately not declared until those features land.
 */
package qv_pkg;

    // Functional-unit routing. All six kinds are named now so the enum
    // never needs to grow; only ALU and BRU are produced so far.
    typedef enum logic [2:0] {
        QV_FU_ALU,
        QV_FU_BRU,
        QV_FU_DIV,
        QV_FU_LSU,
        QV_FU_CSR,
        QV_FU_SYS
    } qv_fu_e;

    // Branch-unit operations (fu_req_t.op for QV_FU_BRU).
    typedef enum logic [2:0] {
        QV_BR_BEQ,
        QV_BR_BNE,
        QV_BR_BLT,
        QV_BR_BGE,
        QV_BR_BLTU,
        QV_BR_BGEU,
        QV_BR_JAL,
        QV_BR_JALR
    } qv_bru_op_e;

    // ROB size is a package constant (not just a module parameter)
    // because packed-struct tag fields need a compile-time width.
    // qv_rob.sv may still be instantiated smaller; the tag is then just
    // wider than strictly needed, which is harmless.
    localparam int QV_ROB_DEPTH = 8;
    localparam int QV_ROB_TAG_W = $clog2(QV_ROB_DEPTH) + 1;  // index + wrap bit

    // Frontend -> instruction queue.
    typedef struct packed {
        logic [63:0] pc;
        logic [31:0] raw;          // full 32-bit encoding ({16'b0, hw} once RVC exists)
        logic        rvc;
        logic        xcpt;         // fetch fault marker
        logic [3:0]  xcpt_cause;
        logic        xcpt_hi;      // fault is in the second dword of a crossing instruction
        logic        pred_taken;
        logic [63:0] pred_tgt;
    } fe_instr_t;

    // Decode -> issue.
    typedef struct packed {
        logic [63:0] pc;
        logic [31:0] raw;
        logic        rvc;
        logic [6:0]  code;         // decoder.sv's o_decoded_instruction, verbatim
        qv_fu_e      fu;
        logic [4:0]  alu_op;       // `ALU_OPSIZE
        qv_bru_op_e  bru_op;
        logic        is_word;      // truncate the result to 32 bits and sign-extend (core.sv's is_word_arith)
        logic [4:0]  rs1;
        logic        rs1_used;
        logic [4:0]  rs2;
        logic        rs2_used;
        logic [4:0]  rd;
        logic        rd_wen;
        logic [63:0] imm1;         // operand A when !rs1_used
        logic [63:0] imm2;         // operand B when !rs2_used
        logic [63:0] imm3;         // branch/JAL pc-relative offset
        logic        xcpt;
        logic [3:0]  xcpt_cause;
    } uop_t;

    // One reorder-buffer entry.
    typedef struct packed {
        logic        valid;
        logic        complete;
        logic [63:0] pc;
        logic [31:0] raw;
        logic [4:0]  rd;
        logic        rd_wen;
        logic [63:0] value;
        logic [63:0] next_pc;      // the predicted next pc until the result overrides it
        logic        mispredict;   // next_pc differs from the prediction: redirect at commit
    } rob_entry_t;

    // RVFI source-operand capture, taken at issue: regfile0 has only two
    // read ports and they belong to whatever is issuing that cycle, so an
    // older instruction's rs1/rs2 values can't be re-read at commit.
    // Always declared (not gated on RISCV_FORMAL) so module port lists
    // stay identical with and without formal; it costs nothing when
    // nothing reads it.
    typedef struct packed {
        logic [4:0]  rs1_addr;
        logic [63:0] rs1_rdata;
        logic [4:0]  rs2_addr;
        logic [63:0] rs2_rdata;
    } rvfi_shadow_t;

    // Issue -> functional unit.
    typedef struct packed {
        logic                    valid;
        logic [QV_ROB_TAG_W-1:0] tag;
        logic [4:0]              op;       // alu_op, or a qv_bru_op_e for the BRU
        logic                    is_word;
        logic [63:0]             a;
        logic [63:0]             b;
        logic [63:0]             pc;
        logic [63:0]             imm;      // uop_t.imm3
        logic                    rvc;
    } fu_req_t;

    // Functional unit -> ROB and bypass (the writeback bus).
    typedef struct packed {
        logic                    valid;
        logic [QV_ROB_TAG_W-1:0] tag;
        logic [63:0]             value;
        logic [63:0]             next_pc;     // meaningful only with mispredict
        logic                    mispredict;
    } wb_t;

    // One producer-table entry (becomes the RAT at O1).
    typedef struct packed {
        logic                    busy;
        logic [QV_ROB_TAG_W-1:0] tag;
    } prod_entry_t;

endpackage
