// SPDX-License-Identifier: MIT

/*
 * qv_pkg -- shared types for the pipelined core (design/pipe/core.sv).
 *
 * Field names follow the pipelining plan's full uop_t/rob_entry_t/
 * fu_req_t/wb_t definitions wherever a field has meaning for the
 * instructions implemented so far, so later increments only ever ADD
 * fields here, never rename one already in use. Fields that only matter
 * to features not built yet (branches, loads/stores, CSR/system ops,
 * traps) are deliberately not declared until those features land.
 */
package qv_pkg;

    // Functional-unit routing. All six kinds are named so the enum never
    // needs to grow. ALU is also where CSR/SYS operands and faulting uops
    // are resolved, so a unit not listed in issue's dispatch (DIV included)
    // would silently execute on the ALU.
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

    // System operations, executed by commit at the ROB head.
    typedef enum logic [2:0] {
        QV_SYS_NONE,
        QV_SYS_ECALL,
        QV_SYS_EBREAK,
        QV_SYS_MRET,
        QV_SYS_WFI,
        QV_SYS_FENCE_I,
        QV_SYS_SRET,
        QV_SYS_SFENCE_VMA
    } qv_sys_op_e;

    // Privilege levels (mstatus.MPP, current_priv). Plain bits rather than an
    // enum: like ref_core.sv, MRET loads MPP raw, so 2'b10 can occur and every
    // privilege compare has to behave as written for it too.
    localparam logic [1:0] QV_PRIV_U = 2'b00;
    localparam logic [1:0] QV_PRIV_S = 2'b01;
    localparam logic [1:0] QV_PRIV_M = 2'b11;

    // A-extension operations (the LSU runs them, at the ROB head). LR and SC
    // are single accesses; the nine AMOs read, modify and write under one lock.
    typedef enum logic [3:0] {
        QV_AMO_LR,
        QV_AMO_SC,
        QV_AMO_SWAP,
        QV_AMO_ADD,
        QV_AMO_XOR,
        QV_AMO_AND,
        QV_AMO_OR,
        QV_AMO_MIN,
        QV_AMO_MAX,
        QV_AMO_MINU,
        QV_AMO_MAXU
    } qv_amo_op_e;

    // CSR read-modify-write kind (the I forms differ only in operand source).
    typedef enum logic [1:0] {
        QV_CSR_RW,
        QV_CSR_RS,
        QV_CSR_RC
    } qv_csr_op_e;

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
        // Where the instruction really is, once fetch is translated (xl): the physical page (PA[55:12]) of the
        // dword it starts in, and for a 32-bit instruction that crosses into the next dword, of that one too.
        // Decode checks the PMP on these; the 64-bit pc stays the virtual address. xl = 0 (Bare, M mode, the
        // Program Buffer): the pc is the physical address.
        logic        xl;
        logic [43:0] pg_lo;
        logic [43:0] pg_hi;
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
        logic        is_word;      // truncate the result to 32 bits and sign-extend (ref_core.sv's is_word_arith)
        logic [4:0]  rs1;
        logic        rs1_used;
        logic [4:0]  rs2;
        logic        rs2_used;
        logic [4:0]  rd;
        logic        rd_wen;
        logic [63:0] imm1;         // operand A when !rs1_used
        logic [63:0] imm2;         // operand B when !rs2_used
        logic [63:0] imm3;         // branch/JAL pc-relative offset, store offset
        logic [1:0]  mem_size;     // bytes = 1 << mem_size
        logic        mem_signed;
        logic        is_load;
        logic        is_store;
        logic        is_atomic;    // LR/SC/AMO: mem_size is 2 (.W) or 3 (.D), always signed
        qv_amo_op_e  amo_op;
        logic        div_signed;   // DIV/REM(W): signed operands
        logic        div_quot;     // DIV(U)(W): the quotient; REM(U)(W): the remainder
        qv_sys_op_e  sys_op;
        qv_csr_op_e  csr_op;
        logic [11:0] csr_addr;
        logic        csr_wsup;     // CSRRS/CSRRC(I) with a zero source: read only
        logic        serialize;    // flush and refetch after this commits
        logic        pred_taken;   // the frontend redirected to pred_tgt after this
        logic [63:0] pred_tgt;
        logic        xcpt;
        logic [3:0]  xcpt_cause;
        logic        xcpt_hi;      // a fetch fault in the second dword of a crossing instruction (tval of a page fault is pc + 8)
        logic        trig_debug;   // an action-1 execute trigger matched its pc: Debug Mode entry instead of executing
        logic        trig_exc;     // an action-0 one did (and no fetch/illegal fault came first): a breakpoint exception
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

    // A memory op's outcome, held by the LSU from its completion until it
    // commits (only the ROB head ever sits in between): its exception, if
    // any, and the RVFI memory fields, following ref_core.sv's conventions
    // (dword-aligned addr, shifted masks, raw bus rdata, shifted wdata).
    typedef struct packed {
        logic        xcpt;
        logic        posted;       // a plain store to RAM whose bus write is left to the store buffer: commit pushes
                                   // {mem_addr, mem_wmask, mem_wdata} into it as the store retires
        logic [3:0]  cause;
        logic [63:0] tval;
        logic [63:0] vaddr;        // the exact access address (LR's reservation address)
        logic [63:0] mem_addr;
        logic [7:0]  mem_rmask;
        logic [7:0]  mem_wmask;
        logic [63:0] mem_rdata;
        logic [63:0] mem_wdata;
    } lsu_res_t;

    // What commit needs to act on an entry beyond its result: exceptions,
    // CSR and system operations. Stored per ROB entry, set at issue.
    typedef struct packed {
        qv_fu_e      cls;          // QV_FU_CSR / QV_FU_SYS act at commit
        qv_sys_op_e  sys_op;
        qv_csr_op_e  csr_op;
        logic [11:0] csr_addr;
        logic        csr_wsup;
        logic        serialize;
        logic        is_lr;        // a clean retirement sets the reservation
        logic        is_store_class; // store, SC or AMO: retiring clears it, faulting or not
        logic        xcpt;
        logic [3:0]  cause;
        logic        xcpt_hi;      // see uop_t
        logic        trig_debug;   // see uop_t
        logic        trig_exc;
    } rob_ctrl_t;

    // Issue -> functional unit.
    typedef struct packed {
        logic                    valid;
        logic [QV_ROB_TAG_W-1:0] tag;
        logic [4:0]              op;       // alu_op; a qv_bru_op_e (BRU); {quot, signed} (DIV); {store, signed, size} or {1, qv_amo_op_e} (LSU)
        logic                    is_word;
        logic [63:0]             a;
        logic [63:0]             b;
        logic [63:0]             pc;
        logic [63:0]             imm;      // uop_t.imm3
        logic                    rvc;
        logic [63:0]             pred_next; // where the frontend went after this
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

    // F/D: what the FPU does (fpu_req_t.op). The precision is fmt (0 single, 1 double: for the conversions between
    // the two, the destination's), the integer type of a conversion ityp (0 W, 1 WU, 2 L, 3 LU: FCVT's rs2 field).
    // FADD/FSUB/FMUL are the FMA with b = 1.0 or no addend (qv_fpu_pipe.sv); DIV and SQRT run in qv_fpu_divsqrt.sv.
    typedef enum logic [4:0] {
        QV_FP_ADD,
        QV_FP_SUB,
        QV_FP_MUL,
        QV_FP_MADD,
        QV_FP_MSUB,
        QV_FP_NMSUB,
        QV_FP_NMADD,
        QV_FP_DIV,
        QV_FP_SQRT,
        QV_FP_SGNJ,
        QV_FP_SGNJN,
        QV_FP_SGNJX,
        QV_FP_MIN,
        QV_FP_MAX,
        QV_FP_EQ,
        QV_FP_LT,
        QV_FP_LE,
        QV_FP_CLASS,
        QV_FP_MV_XF,               // FMV.X.W / FMV.X.D: the register bits to an integer register
        QV_FP_MV_FX,               // FMV.W.X / FMV.D.X: the other way (a single is NaN-boxed)
        QV_FP_F2I,                 // FCVT.{W,WU,L,LU}.{S,D}
        QV_FP_I2F,                 // FCVT.{S,D}.{W,WU,L,LU}
        QV_FP_F2F                  // FCVT.S.D / FCVT.D.S
    } qv_fp_op_e;

    // Issue -> FPU. a, b, c are register values (rs1 an integer for MV_FX and I2F; singles NaN-boxed), rm the
    // rounding mode resolved at decode (frm already substituted for rm = 7).
    typedef struct packed {
        logic                    valid;
        logic [QV_ROB_TAG_W-1:0] tag;
        qv_fp_op_e               op;
        logic                    fmt;
        logic [1:0]              ityp;
        logic [2:0]              rm;
        logic [63:0]             a;
        logic [63:0]             b;
        logic [63:0]             c;
    } fpu_req_t;

    // FPU -> ROB and bypass: the rd value (NaN-boxed for a single result; an integer result sign- or zero-extended
    // to 64 bits as the instruction defines) and the exception flags it raises (NX 1, UF 2, OF 4, DZ 8, NV 16).
    typedef struct packed {
        logic                    valid;
        logic [QV_ROB_TAG_W-1:0] tag;
        logic [63:0]             value;
        logic [4:0]              flags;
    } wb_fp_t;

    // An unpacked FP value, either precision: value = (-1)^s * m * 2^q, with m's MSB (bit 52) set for every finite
    // non-zero value (a single is shifted up by 29 bits, a subnormal normalized). The FPU's datapaths work on this.
    localparam logic [2:0] QV_FPC_ZERO = 3'd0;
    localparam logic [2:0] QV_FPC_SUB  = 3'd1;
    localparam logic [2:0] QV_FPC_NORM = 3'd2;
    localparam logic [2:0] QV_FPC_INF  = 3'd3;
    localparam logic [2:0] QV_FPC_QNAN = 3'd4;
    localparam logic [2:0] QV_FPC_SNAN = 3'd5;
    typedef struct packed {
        logic               s;
        logic [2:0]         cls;
        logic [52:0]        m;
        logic signed [13:0] q;
    } qv_fp_unp_t;

    // A single that is not NaN-boxed (upper 32 bits not all ones) reads as the canonical NaN.
    function automatic logic [63:0] qv_fp_unbox(input logic fmt, input logic [63:0] r);
        if (fmt) return r;
        return {32'b0, (r[63:32] == 32'hFFFF_FFFF) ? r[31:0] : 32'h7FC0_0000};
    endfunction

    // bits: an unboxed value (a single in the low 32 bits)
    function automatic qv_fp_unp_t qv_fp_unpack(input logic fmt, input logic [63:0] bits);
        qv_fp_unp_t         u;
        logic [10:0]        e;
        logic [51:0]        frac;
        logic               emax, ezero, fzero, quiet;
        logic [52:0]        m;
        logic signed [13:0] q;
        int                 lz;
        if (fmt) begin
            u.s = bits[63]; e = bits[62:52]; frac = bits[51:0];
            emax = (e == 11'h7FF); ezero = (e == 11'h000);
        end else begin
            u.s = bits[31]; e = {3'b0, bits[30:23]}; frac = {bits[22:0], 29'b0};
            emax = (e[7:0] == 8'hFF); ezero = (e[7:0] == 8'h00);
        end
        fzero = (frac == 52'b0);
        quiet = frac[51];
        u.m = '0;
        u.q = '0;
        if (emax)             u.cls = fzero ? QV_FPC_INF : (quiet ? QV_FPC_QNAN : QV_FPC_SNAN);
        else if (ezero && fzero) u.cls = QV_FPC_ZERO;
        else begin
            u.cls = ezero ? QV_FPC_SUB : QV_FPC_NORM;
            m = {!ezero, frac};                      // a single's 23 fraction bits are already at the top
            // q = E - bias - 52 (doubles) or E - bias - 23 - 29 (singles: shifted up by 29), E = 1 for a subnormal
            q = fmt ? (14'(ezero ? 11'd1 : e) - 14'sd1075) : (14'(ezero ? 11'd1 : e) - 14'sd179);
            lz = 53;
            for (int i = 0; i <= 52; i++)               // the highest set bit wins
                if (m[i]) lz = 52 - i;
            u.m = m << lz;
            u.q = q - 14'(lz);
        end
        return u;
    endfunction

    // What kind of control-flow instruction an encoding is (32-bit, or RVC with raw[31:16] = 0), for the branch
    // predictors: 0 none, 1 direct (conditional branch, JAL, C.J, C.BEQZ/C.BNEZ: the target is in the encoding),
    // 2 an indirect jump that is not a return (JALR, C.JR, C.JALR: the target is a register; a call or a jump),
    // 3 a return (JALR/C.JR with rd = x0 and rs1 = x1 or x5).
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [1:0] qv_ctl_kind(input logic [31:0] raw);
        logic [4:0] rd, rs1;
        if (raw[1:0] == 2'b11) begin
            rd  = raw[11:7];
            rs1 = raw[19:15];
            if (raw[6:0] == 7'b1100011 && raw[14:13] != 2'b01) return 2'd1;       // conditional branch
            if (raw[6:0] == 7'b1101111)                        return 2'd1;       // JAL
            if (raw[6:0] == 7'b1100111 && raw[14:12] == 3'b000)
                return (rd == 5'd0 && (rs1 == 5'd1 || rs1 == 5'd5)) ? 2'd3 : 2'd2;
            return 2'd0;
        end else begin
            if (raw[1:0] == 2'b01 && raw[15:13] == 3'b101)     return 2'd1;       // C.J
            if (raw[1:0] == 2'b01 && raw[15:14] == 2'b11)      return 2'd1;       // C.BEQZ / C.BNEZ
            if (raw[1:0] == 2'b10 && raw[15:13] == 3'b100 && raw[6:2] == 5'd0 && raw[11:7] != 5'd0) begin
                rs1 = raw[11:7];
                if (!raw[12] && (rs1 == 5'd1 || rs1 == 5'd5)) return 2'd3;       // C.JR ra / t0
                return 2'd2;                                                      // C.JR, C.JALR
            end
            return 2'd0;
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // A conditional branch (32-bit, or C.BEQZ/C.BNEZ).
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic qv_is_cond(input logic [31:0] raw);
        if (raw[1:0] == 2'b11) return raw[6:0] == 7'b1100011 && raw[14:13] != 2'b01;
        else                   return raw[1:0] == 2'b01 && raw[15:14] == 2'b11;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // A call: JAL or JALR that links to ra or t0 (the return address is then pushed on the return-address stack), and
    // C.JALR (which links to ra).
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic qv_is_call(input logic [31:0] raw);
        if (raw[1:0] == 2'b11)
            return (raw[6:0] == 7'b1101111 || (raw[6:0] == 7'b1100111 && raw[14:12] == 3'b000))
                   && (raw[11:7] == 5'd1 || raw[11:7] == 5'd5);
        else
            return raw[1:0] == 2'b10 && raw[15:12] == 4'b1001 && raw[6:2] == 5'd0 && raw[11:7] != 5'd0;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

endpackage
