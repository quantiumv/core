// SPDX-License-Identifier: MIT

`include "defaults/defaults.sv"
`include "defaults/alu_ops.sv"
`include "defaults/instruction_format.sv"

/*
 * qv_decode -- the D stage: decoder.sv plus the uop builder.
 *
 * decoder.sv is reused unmodified with its register-data inputs tied to
 * 0. It computes o_imm_N = (o_read_gpr_N_sel != 0) ? i_read_gpr_N_data :
 * internal_imm_N, so with the data tied off, o_imm_N is the decoded
 * immediate when no register is selected and 0 when one is. That gives
 * "register or immediate" plus the immediate value in one pass; issue
 * supplies the register value later. A source of x0 (sel == 0) reads as
 * the immediate 0, which is architecturally the same thing and means x0
 * never needs a producer-table lookup.
 *
 * Classification mirrors ref_core.sv case by case: alu_op from its
 * alu_op_sel block (branches, JAL and JALR go to the BRU instead, with
 * imm3 = the B or J offset), rd_wen from its reg_write_control exclusion list
 * (the full list, so adding an instruction later is a new arm, not a new
 * mechanism). Only the codes in `implemented` below actually execute;
 * anything else is marked as an illegal-instruction fault (cause 2) --
 * permanently correct for INVALID, and a "not built yet" marker for the
 * rest until their features land. A fetch fault (cause from align) takes
 * priority. A faulting uop never writes rd.
 *
 * RVC goes through c_expand.sv first; raw (and so RVFI's insn and an
 * illegal instruction's mtval) keeps the original {16'b0, halfword}.
 *
 * decoder.sv must come before this file in the compile order: the
 * INSTR_CODE macro is defined there, the same requirement ref_core.sv has.
 *
 * The privilege rules (CSR privilege, MRET/SRET, TSR, TVM) read the
 * current privilege and mstatus bits as inputs; see the port comment.
 *
 * PMP is checked here, per instruction and per 2-byte parcel, as Sail
 * fetches (errata E6): the first parcel [pc, pc+1] and, for a 32-bit
 * instruction, the second [pc+2, pc+3], at the raw privilege (MPRV never
 * applies to fetch). With translation on (fe_instr_t.xl) they are the
 * physical addresses fetch found: {pg_lo, pc[11:0]}, and the second
 * parcel's page is pg_hi when the instruction crosses into the next dword
 * (pc[2:1] == 2'b11), pg_lo otherwise. A denial is a fetch access fault
 * (cause 1), the same marker a bus error gets; one in the second parcel
 * marks the uop xcpt_hi, so mtval is pc + 2. Unlike ref_core.sv the bus
 * request has already been made by then; a denied fetch is just never used.
 * The parcels go in order, as in ref_core.sv: a denial of the first beats a
 * fault marker of the second (a page fault in the next dword, say), which
 * beats a denial of the second.
 *
 * Execute triggers (the two mcontrol6 slots, ref_core.sv's trig0/trig1) are
 * matched here, on the instruction's own pc and the current privilege, and
 * never in Debug Mode: an action-1 match marks the uop trig_debug (Debug Mode
 * entry at the head, before the instruction has any effect, even over a fetch
 * fault or an illegal instruction), an action-0 match with no such fault
 * marks it trig_exc (a breakpoint exception, cause 3). A debug match beats an
 * exception one. Either way the uop is neutralised -- sent through the ALU as
 * a no-op that writes nothing -- so nothing can happen before it reaches the
 * head: no memory access, divide, CSR write or system action, and no
 * producer-table entry for a result that never comes. Only that: its
 * operands and the flags that make commit clear the LR/SC reservation are
 * left alone (ref_core.sv clears it when a store, SC or AMO traps on an action-0
 * trigger, and the trapping instruction still reports its real operands).
 * An EBREAK keeps its identity: with dcsr.ebreak* set it enters Debug Mode
 * ahead of the trigger.
 *
 * Output is registered (a real D/I split): one uop held until issue
 * takes it.
 *
 * CSR_NOSER (P10c): a CSR op serializes (flush and refetch at commit) only if
 * it can change what a younger instruction does. One that writes nothing (the
 * read-only forms, csr_wsup) or writes a trap CSR (m/s scratch, epc, cause,
 * tval: only commit and CSR ops read those, both at the head) does not; issue
 * makes its dependents wait for its commit, where its rd value is made.
 */
module qv_decode #(
    parameter bit FPU_EN = 1'b0,          // F/D: the FP encodings are instructions (else illegal, as before)
    parameter bit CSR_NOSER = 1'b0
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              i_flush,

    // privilege state the illegal-instruction rules depend on. Live values
    // are exact: every change to them is a trap, an xRET (both redirect) or
    // a CSR write (serializes), each of which flushes decode before a
    // younger instruction can be decoded against a stale value.
    input  logic [1:0]        i_priv,
    input  logic              i_tsr,
    input  logic              i_tvm,
    // F/D: mstatus.FS (Off makes every FP instruction and fcsr access illegal) and frm (rm = 7). Live values are
    // exact: writes to them serialize, and a commit's step to Dirty never changes what is legal.
    input  logic [1:0]        i_fs  = 2'b00,
    input  logic [2:0]        i_frm = 3'b000,
    // Debug Mode: the debug and trigger CSRs exist only there (outside it they are illegal for every
    // privilege level), and the usual privilege rule still applies inside it
    input  logic              i_in_debug = 1'b0,
    // a Program Buffer run is trusted: its instructions are not PMP-checked
    input  logic              i_pb_active = 1'b0,

    // the two execute triggers (csr_file0's tdata1/tdata2 exports); the defaults are "never matches"
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]       i_tdata1_0  = 64'b0,
    input  logic [63:0]       i_tdata2_0  = 64'b0,
    input  logic [63:0]       i_tdata1_1  = 64'b0,
    input  logic [63:0]       i_tdata2_1  = 64'b0,
    /* verilator lint_on UNUSEDSIGNAL */

    // PMP configuration (csr_file0's exports); the defaults are the reset
    // state: region 0 NAPOT over everything, read/write/execute
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]       i_pmpcfg0   = 64'h0000_0000_0000_001F,
    input  logic [63:0]       i_pmpaddr0  = 64'h003F_FFFF_FFFF_FFFF,
    input  logic [63:0]       i_pmpaddr1  = 64'b0,
    input  logic [63:0]       i_pmpaddr2  = 64'b0,
    input  logic [63:0]       i_pmpaddr3  = 64'b0,
    /* verilator lint_on UNUSEDSIGNAL */

    input  logic              i_iq_valid,
    input  qv_pkg::fe_instr_t i_iq_data,
    output logic              o_iq_pop,

    output logic              o_valid,
    output qv_pkg::uop_t      o_uop,
    input  logic              i_issue_ready
);
    import qv_pkg::*;

    logic [(`L2_REG_FILE_SIZE - 1):0] sel_a, sel_b;
    logic [(`INSTR_CODE_SIZE - 1):0]  code;
    logic [(`WORD_SIZE - 1):0]        imm_1, imm_2;
    logic [(`B_IMM_SIZE - 1):0]       imm_3_or_dest_addr;   // rd, or a branch's B offset

    // RVC expands to its 32-bit equivalent. A faulted fetch or a reserved
    // compressed encoding decodes as ref_core.sv's inert placeholder (addi
    // x0, x0, 0) instead, so nothing downstream acts on the bits; the
    // trap itself is the xcpt marking below.
    logic [31:0] expanded;
    logic        c_expand_illegal;
    c_expand c_expand0 (
        .i_instr16(i_iq_data.raw[15:0]),
        .o_instr32(expanded),
        .o_illegal(c_expand_illegal)
    );
    wire c_illegal = i_iq_data.rvc && c_expand_illegal;

    // ---------------- PMP on the fetch ----------------
    // Per 2-byte parcel, at physical addresses. Fetch not translated (xl low): the pc is the address. Translated:
    // the first parcel is at {pg_lo, pc[11:0]}, the second (a 32-bit instruction's) at pc + 2 on pg_hi if the
    // instruction crosses into the next dword, pg_lo if not.
    wire        crosses   = !i_iq_data.rvc && (i_iq_data.pc[2:1] == 2'b11);
    wire [11:0] pc_hi_off = i_iq_data.pc[11:0] + 12'd2;
    wire [43:0] pg_p2     = crosses ? i_iq_data.pg_hi : i_iq_data.pg_lo;
    wire [63:0] pa_lo = i_iq_data.xl ? {8'b0, i_iq_data.pg_lo, i_iq_data.pc[11:0]} : i_iq_data.pc;
    wire [63:0] pa_hi = i_iq_data.xl ? {8'b0, pg_p2, pc_hi_off}                    : i_iq_data.pc + 64'd2;
    logic       exec_ok_lo, exec_ok_hi;
    /* verilator lint_off PINCONNECTEMPTY */
    qv_pmp pmp_lo (
        .i_pmpcfg0(i_pmpcfg0), .i_pmpaddr0(i_pmpaddr0), .i_pmpaddr1(i_pmpaddr1),
        .i_pmpaddr2(i_pmpaddr2), .i_pmpaddr3(i_pmpaddr3),
        .i_addr(pa_lo), .i_end(pa_lo + 64'd1), .i_priv(i_priv),
        .o_read_ok(), .o_write_ok(), .o_exec_ok(exec_ok_lo)
    );
    qv_pmp pmp_hi (
        .i_pmpcfg0(i_pmpcfg0), .i_pmpaddr0(i_pmpaddr0), .i_pmpaddr1(i_pmpaddr1),
        .i_pmpaddr2(i_pmpaddr2), .i_pmpaddr3(i_pmpaddr3),
        .i_addr(pa_hi), .i_end(pa_hi + 64'd1), .i_priv(i_priv),
        .o_read_ok(), .o_write_ok(), .o_exec_ok(exec_ok_hi)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    wire lo_denied = !i_pb_active && !exec_ok_lo;
    wire hi_denied = !i_pb_active && !i_iq_data.rvc && !exec_ok_hi;
    wire pmp_fault = lo_denied || hi_denied;
    // ref_core.sv fetches the first parcel first and ends there when the PMP denies it: a fault found later, in the
    // second (a page fault in the next dword, say), never happens. The marker of such a fault gives way to the denial.
    wire marker_lo_denied = i_iq_data.xcpt && i_iq_data.xcpt_hi && lo_denied;

    // a denied fetch decodes as the inert placeholder too: nothing downstream may act on its bits
    wire [31:0] instr = (i_iq_data.xcpt || pmp_fault || c_illegal) ? 32'h0000_0013
                      : i_iq_data.rvc ? expanded : i_iq_data.raw;

    decoder decoder0 (
        .i_instruction(instr),
        .i_instruction_address(i_iq_data.pc),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_instruction_address(),
        /* verilator lint_on PINCONNECTEMPTY */
        .o_read_gpr_A_sel(sel_a),
        .i_read_gpr_A_data('0),
        .o_read_gpr_B_sel(sel_b),
        .i_read_gpr_B_data('0),
        .o_decoded_instruction(code),
        .o_imm_1(imm_1),
        .o_imm_2(imm_2),
        .o_imm_3_or_dest_addr(imm_3_or_dest_addr)
    );

    // F/D: the FP encodings keep decoder.sv's INVALID code; qv_fp_dec classifies them from the same bits (after RVC
    // expansion and the fault placeholder, so a faulted fetch is never one)
    logic        fp_is, fp_ill, fp_fmt, fp_ld, fp_st, fp_r1u, fp_r1f, fp_r2u, fp_r2f, fp_r3u, fp_rdw, fp_rdf;
    qv_fp_op_e   fp_op;
    logic [1:0]  fp_ityp, fp_msz;
    logic [2:0]  fp_rm;
    logic [63:0] fp_imm;
    qv_fp_dec fpdec0 (
        .i_instr(instr), .i_fs(i_fs), .i_frm(i_frm),
        .o_is_fp(fp_is), .o_illegal(fp_ill), .o_op(fp_op), .o_fmt(fp_fmt), .o_ityp(fp_ityp), .o_rm(fp_rm),
        .o_is_load(fp_ld), .o_is_store(fp_st), .o_mem_size(fp_msz), .o_imm(fp_imm),
        .o_rs1_used(fp_r1u), .o_rs1_fp(fp_r1f), .o_rs2_used(fp_r2u), .o_rs2_fp(fp_r2f), .o_rs3_used(fp_r3u),
        .o_rd_wen(fp_rdw), .o_rd_fp(fp_rdf)
    );
    wire is_fp = FPU_EN && fp_is;

    logic [(`ALU_OPSIZE - 1):0] alu_op;
    logic                       is_alu;
    always_comb begin: alu_op_sel
        is_alu = 1'b1;
        case (code)
            // LUI: imm1 + imm2(=0). AUIPC: pc + imm, see uop_d below.
            `INSTR_CODE(ADDI), `INSTR_CODE(ADD),
            `INSTR_CODE(ADDIW), `INSTR_CODE(ADDW),
            `INSTR_CODE(LUI), `INSTR_CODE(AUIPC):    alu_op = `ADD;
            `INSTR_CODE(SUB), `INSTR_CODE(SUBW):     alu_op = `SUB;
            `INSTR_CODE(SLTI), `INSTR_CODE(SLT):     alu_op = `SLT;
            `INSTR_CODE(SLTIU), `INSTR_CODE(SLTU):   alu_op = `SLTU;
            `INSTR_CODE(XORI), `INSTR_CODE(XOR):     alu_op = `XOR;
            `INSTR_CODE(ORI), `INSTR_CODE(OR):       alu_op = `OR;
            `INSTR_CODE(ANDI), `INSTR_CODE(AND):     alu_op = `AND;
            `INSTR_CODE(SLLI), `INSTR_CODE(SLL):     alu_op = `SLL;
            `INSTR_CODE(SRLI), `INSTR_CODE(SRL):     alu_op = `SRL;
            `INSTR_CODE(SRAI), `INSTR_CODE(SRA):     alu_op = `SRA;
            `INSTR_CODE(SLLIW), `INSTR_CODE(SLLW):   alu_op = `SLLW;
            `INSTR_CODE(SRLIW), `INSTR_CODE(SRLW):   alu_op = `SRLW;
            `INSTR_CODE(SRAIW), `INSTR_CODE(SRAW):   alu_op = `SRAW;
            `INSTR_CODE(MUL), `INSTR_CODE(MULW):     alu_op = `MUL;
            `INSTR_CODE(MULH):                       alu_op = `MULH;
            `INSTR_CODE(MULHSU):                     alu_op = `MULHSU;
            `INSTR_CODE(MULHU):                      alu_op = `MULHU;
            default: begin
                alu_op = `ADD;
                is_alu = 1'b0;
            end
        endcase
    end: alu_op_sel

    logic       is_bru;
    qv_bru_op_e bru_op;
    always_comb begin: bru_op_sel
        is_bru = 1'b1;
        case (code)
            `INSTR_CODE(BEQ):  bru_op = QV_BR_BEQ;
            `INSTR_CODE(BNE):  bru_op = QV_BR_BNE;
            `INSTR_CODE(BLT):  bru_op = QV_BR_BLT;
            `INSTR_CODE(BGE):  bru_op = QV_BR_BGE;
            `INSTR_CODE(BLTU): bru_op = QV_BR_BLTU;
            `INSTR_CODE(BGEU): bru_op = QV_BR_BGEU;
            `INSTR_CODE(JAL):  bru_op = QV_BR_JAL;
            `INSTR_CODE(JALR): bru_op = QV_BR_JALR;
            default: begin
                bru_op = QV_BR_BEQ;
                is_bru = 1'b0;
            end
        endcase
    end: bru_op_sel

    logic       is_csr, csr_imm;
    qv_csr_op_e csr_op;
    always_comb begin: csr_op_sel
        is_csr  = 1'b1;
        csr_imm = 1'b0;
        case (code)
            `INSTR_CODE(CSRRW):  csr_op = QV_CSR_RW;
            `INSTR_CODE(CSRRS):  csr_op = QV_CSR_RS;
            `INSTR_CODE(CSRRC):  csr_op = QV_CSR_RC;
            `INSTR_CODE(CSRRWI): begin csr_op = QV_CSR_RW; csr_imm = 1'b1; end
            `INSTR_CODE(CSRRSI): begin csr_op = QV_CSR_RS; csr_imm = 1'b1; end
            `INSTR_CODE(CSRRCI): begin csr_op = QV_CSR_RC; csr_imm = 1'b1; end
            default: begin
                csr_op = QV_CSR_RW;
                is_csr = 1'b0;
            end
        endcase
    end: csr_op_sel

    logic       is_sys;
    qv_sys_op_e sys_op;
    always_comb begin: sys_op_sel
        is_sys = 1'b1;
        case (code)
            `INSTR_CODE(ECALL):  sys_op = QV_SYS_ECALL;
            `INSTR_CODE(EBREAK): sys_op = QV_SYS_EBREAK;
            `INSTR_CODE(MRET):   sys_op = QV_SYS_MRET;
            `INSTR_CODE(SRET):   sys_op = QV_SYS_SRET;
            `INSTR_CODE(SFENCE_VMA): sys_op = QV_SYS_SFENCE_VMA;
            `INSTR_CODE(WFI):    sys_op = QV_SYS_WFI;
            `INSTR_CODE(FENCE_I): sys_op = QV_SYS_FENCE_I;
            default: begin
                sys_op = QV_SYS_NONE;
                is_sys = 1'b0;
            end
        endcase
    end: sys_op_sel

    // loads/stores (ref_core.sv's mem_control); FENCE retires as a no-op
    // through the ALU, since memory ops already complete in order
    logic       is_load, is_store, mem_signed;
    logic [1:0] mem_size;
    always_comb begin: mem_control
        is_load    = 1'b0;
        is_store   = 1'b0;
        mem_signed = 1'b0;
        mem_size   = 2'd0;
        case (code)
            `INSTR_CODE(LB):  begin is_load  = 1'b1; mem_size = 2'd0; mem_signed = 1'b1; end
            `INSTR_CODE(LH):  begin is_load  = 1'b1; mem_size = 2'd1; mem_signed = 1'b1; end
            `INSTR_CODE(LW):  begin is_load  = 1'b1; mem_size = 2'd2; mem_signed = 1'b1; end
            `INSTR_CODE(LD):  begin is_load  = 1'b1; mem_size = 2'd3; mem_signed = 1'b1; end
            `INSTR_CODE(LBU): begin is_load  = 1'b1; mem_size = 2'd0; end
            `INSTR_CODE(LHU): begin is_load  = 1'b1; mem_size = 2'd1; end
            `INSTR_CODE(LWU): begin is_load  = 1'b1; mem_size = 2'd2; end
            `INSTR_CODE(SB):  begin is_store = 1'b1; mem_size = 2'd0; end
            `INSTR_CODE(SH):  begin is_store = 1'b1; mem_size = 2'd1; end
            `INSTR_CODE(SW):  begin is_store = 1'b1; mem_size = 2'd2; end
            `INSTR_CODE(SD):  begin is_store = 1'b1; mem_size = 2'd3; end
            default: ;
        endcase
    end: mem_control
    // A extension (ref_core.sv's mem_control): LR/SC and the nine AMOs, .W and .D.
    // The address is rs1 alone; the LSU runs them at the ROB head.
    logic       is_atomic, atomic_word;
    qv_amo_op_e amo_op;
    always_comb begin: atomic_control
        is_atomic   = 1'b1;
        atomic_word = 1'b0;
        amo_op      = QV_AMO_LR;
        case (code)
            `INSTR_CODE(LR_W):      begin amo_op = QV_AMO_LR;   atomic_word = 1'b1; end
            `INSTR_CODE(LR_D):      begin amo_op = QV_AMO_LR; end
            `INSTR_CODE(SC_W):      begin amo_op = QV_AMO_SC;   atomic_word = 1'b1; end
            `INSTR_CODE(SC_D):      begin amo_op = QV_AMO_SC; end
            `INSTR_CODE(AMOSWAP_W): begin amo_op = QV_AMO_SWAP; atomic_word = 1'b1; end
            `INSTR_CODE(AMOSWAP_D): begin amo_op = QV_AMO_SWAP; end
            `INSTR_CODE(AMOADD_W):  begin amo_op = QV_AMO_ADD;  atomic_word = 1'b1; end
            `INSTR_CODE(AMOADD_D):  begin amo_op = QV_AMO_ADD; end
            `INSTR_CODE(AMOXOR_W):  begin amo_op = QV_AMO_XOR;  atomic_word = 1'b1; end
            `INSTR_CODE(AMOXOR_D):  begin amo_op = QV_AMO_XOR; end
            `INSTR_CODE(AMOAND_W):  begin amo_op = QV_AMO_AND;  atomic_word = 1'b1; end
            `INSTR_CODE(AMOAND_D):  begin amo_op = QV_AMO_AND; end
            `INSTR_CODE(AMOOR_W):   begin amo_op = QV_AMO_OR;   atomic_word = 1'b1; end
            `INSTR_CODE(AMOOR_D):   begin amo_op = QV_AMO_OR; end
            `INSTR_CODE(AMOMIN_W):  begin amo_op = QV_AMO_MIN;  atomic_word = 1'b1; end
            `INSTR_CODE(AMOMIN_D):  begin amo_op = QV_AMO_MIN; end
            `INSTR_CODE(AMOMAX_W):  begin amo_op = QV_AMO_MAX;  atomic_word = 1'b1; end
            `INSTR_CODE(AMOMAX_D):  begin amo_op = QV_AMO_MAX; end
            `INSTR_CODE(AMOMINU_W): begin amo_op = QV_AMO_MINU; atomic_word = 1'b1; end
            `INSTR_CODE(AMOMINU_D): begin amo_op = QV_AMO_MINU; end
            `INSTR_CODE(AMOMAXU_W): begin amo_op = QV_AMO_MAXU; atomic_word = 1'b1; end
            `INSTR_CODE(AMOMAXU_D): begin amo_op = QV_AMO_MAXU; end
            default:                is_atomic = 1'b0;
        endcase
    end: atomic_control

    wire is_mem   = is_load || is_store || is_atomic;
    wire is_fence = (code == `INSTR_CODE(FENCE));

    // ---------------- execute triggers ----------------
    // priv_en is bit 6 (M), 4 (S) or 3 (anything else, privilege 2'b10 included), as in ref_core.sv
    wire t0_priv_en = (i_priv == QV_PRIV_M) ? i_tdata1_0[6] : (i_priv == QV_PRIV_S) ? i_tdata1_0[4] : i_tdata1_0[3];
    wire t1_priv_en = (i_priv == QV_PRIV_M) ? i_tdata1_1[6] : (i_priv == QV_PRIV_S) ? i_tdata1_1[4] : i_tdata1_1[3];
    wire t0_match   = i_tdata1_0[2] && t0_priv_en && (i_iq_data.pc == i_tdata2_0);
    wire t1_match   = i_tdata1_1[2] && t1_priv_en && (i_iq_data.pc == i_tdata2_1);
    wire trig_debug_c = !i_in_debug && ((t0_match && i_tdata1_0[15:12] == 4'd1) || (t1_match && i_tdata1_1[15:12] == 4'd1));
    wire trig_exc_c   = !i_in_debug && !trig_debug_c
                        && ((t0_match && i_tdata1_0[15:12] == 4'd0) || (t1_match && i_tdata1_1[15:12] == 4'd0));

    // DIV/DIVU/REM/REMU and the W forms (ref_core.sv's is_div_family): a
    // multi-cycle unit of its own, qv_exu_div
    logic is_div, div_signed, div_quot, div_word;
    always_comb begin: div_control
        is_div     = 1'b1;
        div_signed = 1'b0;
        div_quot   = 1'b0;
        div_word   = 1'b0;
        case (code)
            `INSTR_CODE(DIV):   begin div_signed = 1'b1; div_quot = 1'b1; end
            `INSTR_CODE(DIVU):  begin div_quot = 1'b1; end
            `INSTR_CODE(REM):   begin div_signed = 1'b1; end
            `INSTR_CODE(REMU):  ;
            `INSTR_CODE(DIVW):  begin div_signed = 1'b1; div_quot = 1'b1; div_word = 1'b1; end
            `INSTR_CODE(DIVUW): begin div_quot = 1'b1; div_word = 1'b1; end
            `INSTR_CODE(REMW):  begin div_signed = 1'b1; div_word = 1'b1; end
            `INSTR_CODE(REMUW): begin div_word = 1'b1; end
            default:            is_div = 1'b0;
        endcase
    end: div_control

    wire implemented = is_alu || is_bru || is_csr || is_sys || is_mem || is_fence || is_div || is_fp;

    // The CSR address arrives on imm_2. Write suppression and illegality
    // mirror ref_core.sv's csr_write_suppress / is_illegal_instr for M-mode:
    // RS/RC suppress on the rs1 FIELD being x0, the I forms on uimm == 0;
    // a non-suppressed write to a read-only CSR (addr[11:10] == 11) and
    // any access to the debug (0x7B0-0x7B3) or trigger (0x7A0-0x7A4)
    // CSRs outside debug mode are illegal. The privilege-dependent rules
    // follow below.
    wire [11:0] csr_addr = imm_2[11:0];
    wire csr_wsup = (csr_op != QV_CSR_RW) && (csr_imm ? (imm_1 == '0) : (sel_a == '0));
    wire csr_debug_addr = csr_addr[11:2] == 10'h1EC
                          || csr_addr[11:2] == 10'h1E8 || csr_addr == 12'h7A4;
    wire csr_illegal = is_csr && ((!csr_wsup && csr_addr[11:10] == 2'b11)
                                  || (csr_debug_addr && !i_in_debug));
    // errata E10: a CSR that does not exist is illegal, from every privilege level and for every access, the
    // read-suppressed forms included (qv_csr_exists.sv has the set; E7's absent PMP CSRs are part of it)
    logic csr_exists;
    qv_csr_exists #(.FP_EN(FPU_EN)) csr_exists0 (.i_addr(csr_addr), .o_exists(csr_exists));
    wire csr_absent = is_csr && !csr_exists;
    // the trap CSRs: mscratch, mepc, mcause, mtval (0x340-0x343) and sscratch, sepc, scause, stval (0x140-0x143)
    wire csr_trap_wr = (csr_addr[11:2] == 10'h0D0) || (csr_addr[11:2] == 10'h050);

    // Privilege rules, literally ref_core.sv's (its comments say why each is so):
    // a CSR above the current privilege (addr[9:8] is the lowest privilege
    // that may touch it); MRET outside M; SRET in U, or in S with TSR; an S-mode
    // satp access or SFENCE.VMA under TVM. WFI traps nowhere (no TW) and
    // SFENCE.VMA is legal from U.
    wire is_mret_op = (sys_op == QV_SYS_MRET);
    wire is_sret_op = (sys_op == QV_SYS_SRET);
    wire is_sfence  = (sys_op == QV_SYS_SFENCE_VMA);
    wire csr_priv_violation  = is_csr && (csr_addr[9:8] > i_priv);
    wire mret_priv_violation = is_mret_op && (i_priv != QV_PRIV_M);
    wire sret_priv_violation = is_sret_op && ((i_priv == QV_PRIV_U) || (i_priv == QV_PRIV_S && i_tsr));
    wire tvm_violation       = i_tvm && (i_priv == QV_PRIV_S) && ((is_csr && csr_addr == 12'h180) || is_sfence);
    wire priv_illegal = csr_priv_violation || mret_priv_violation || sret_priv_violation || tvm_violation;
    // F/D: a reserved FP encoding or rounding mode, FS Off; fflags/frm/fcsr with FS Off (without the FPU they do
    // not exist: csr_absent)
    wire fp_illegal = (is_fp && fp_ill)
                      || (FPU_EN && is_csr && (csr_addr == 12'h001 || csr_addr == 12'h002 || csr_addr == 12'h003)
                          && i_fs == 2'b00);

    logic reg_write_ctrl;
    always_comb begin: reg_write_control
        case (code)
            `INSTR_CODE(SB), `INSTR_CODE(SH), `INSTR_CODE(SW), `INSTR_CODE(SD),
            `INSTR_CODE(BEQ), `INSTR_CODE(BNE), `INSTR_CODE(BLT),
            `INSTR_CODE(BGE), `INSTR_CODE(BLTU), `INSTR_CODE(BGEU),
            `INSTR_CODE(FENCE), `INSTR_CODE(FENCE_I), `INSTR_CODE(ECALL), `INSTR_CODE(EBREAK),
            `INSTR_CODE(MRET), `INSTR_CODE(SRET), `INSTR_CODE(WFI), `INSTR_CODE(SFENCE_VMA),
            `INSTR_CODE(INVALID):
                reg_write_ctrl = 1'b0;
            default:
                reg_write_ctrl = 1'b1;
        endcase
    end: reg_write_control

    // ADDW/SUBW/ADDIW/MULW reuse the 64-bit op and get truncated after;
    // the *W shifts have their own 32-bit ALU ops (ref_core.sv's is_word_arith).
    // The W divides also work on 32-bit operands and a sign-extended result,
    // and the LSU takes .W atomics' width from this flag.
    wire is_word = (code == `INSTR_CODE(ADDW)) || (code == `INSTR_CODE(SUBW))
                || (code == `INSTR_CODE(ADDIW)) || (code == `INSTR_CODE(MULW))
                || div_word || (is_atomic && atomic_word);
    wire is_auipc = (code == `INSTR_CODE(AUIPC));
    wire is_jal   = (code == `INSTR_CODE(JAL));

    wire [(`WORD_SIZE - 1):0] imm_b_sext =
        {{(`WORD_SIZE - `B_IMM_SIZE){imm_3_or_dest_addr[`B_IMM_SIZE - 1]}}, imm_3_or_dest_addr};

    uop_t uop_d;
    always_comb begin
        uop_d          = '0;
        uop_d.pc       = i_iq_data.pc;
        uop_d.raw      = i_iq_data.raw;
        uop_d.rvc      = i_iq_data.rvc;
        uop_d.code     = code;
        uop_d.alu_op   = alu_op;
        uop_d.bru_op   = bru_op;
        uop_d.is_word  = is_word;
        uop_d.rs1      = sel_a;
        uop_d.rs1_used = (sel_a != '0);
        uop_d.rs2      = sel_b;
        uop_d.rs2_used = (sel_b != '0);
        uop_d.rd       = imm_3_or_dest_addr[(`L2_REG_FILE_SIZE - 1):0];
        // AUIPC uses no registers, so pc can ride in as an immediate. A
        // CSR op's ALU pass gives just its source (rs1 or uimm) + 0.
        uop_d.imm1     = is_auipc ? i_iq_data.pc : imm_1;
        uop_d.imm2     = is_auipc ? imm_1 : is_csr ? '0 : imm_2;
        uop_d.imm3     = is_jal ? imm_1 : imm_b_sext;
        uop_d.sys_op   = sys_op;
        uop_d.csr_op   = csr_op;
        uop_d.csr_addr = csr_addr;
        uop_d.csr_wsup = csr_wsup;
        // a CSR op that may change what anything younger does flushes and
        // refetches after it (with CSR_NOSER the others do not: see the header;
        // their rd value exists only at commit, and issue waits for it).
        // FENCE.I refetches everything after it.
        uop_d.serialize = (is_csr && !(CSR_NOSER && (csr_wsup || csr_trap_wr)))
                          || (sys_op == QV_SYS_FENCE_I) || is_sfence;
        uop_d.pred_taken = i_iq_data.pred_taken;
        uop_d.pred_tgt   = i_iq_data.pred_tgt;
        uop_d.mem_size   = is_atomic ? (atomic_word ? 2'd2 : 2'd3) : mem_size;
        uop_d.mem_signed = mem_signed;                   // (atomics: the LSU always sign-extends them)
        uop_d.is_atomic  = is_atomic;
        uop_d.amo_op     = amo_op;
        uop_d.is_load    = is_load;
        uop_d.is_store   = is_store;
        uop_d.div_signed = div_signed;
        uop_d.div_quot   = div_quot;
        uop_d.xcpt_hi    = i_iq_data.xcpt_hi;
        if (is_fp && !fp_ill) begin                     // F/D: operands and destination from the bits (an illegal one has none, as in ref_core.sv)
            uop_d.rs1        = fp_r1u ? instr[19:15] : 5'd0;     // unused: 0, as decoder.sv gives
            uop_d.rs1_used   = fp_r1u;
            uop_d.rs1_fp     = fp_r1f;
            uop_d.rs2        = fp_r2u ? instr[24:20] : 5'd0;     // (FCVT and FSQRT keep a type there)
            uop_d.rs2_used   = fp_r2u;
            uop_d.rs2_fp     = fp_r2f;
            uop_d.rs3        = fp_r3u ? instr[31:27] : 5'd0;
            uop_d.rs3_used   = fp_r3u;
            uop_d.rd         = instr[11:7];
            uop_d.rd_fp      = fp_rdf;
            uop_d.fp_op      = 5'(fp_op);
            uop_d.fp_fmt     = fp_fmt;
            uop_d.fp_ityp    = fp_ityp;
            uop_d.fp_rm      = fp_rm;
            uop_d.is_load    = fp_ld;
            uop_d.is_store   = fp_st;
            uop_d.mem_size   = fp_msz;
            uop_d.mem_signed = 1'b0;
            uop_d.imm2       = fp_imm;                   // a load's offset: the LSU's operand b
            uop_d.imm3       = fp_imm;                   // a store's
        end else if (is_fp) begin                        // an illegal one reads nothing (ref_core.sv decodes it as 0)
            uop_d.rs1      = 5'd0;
            uop_d.rs1_used = 1'b0;
            uop_d.rs2      = 5'd0;
            uop_d.rs2_used = 1'b0;
        end
        if (i_iq_data.xcpt && !marker_lo_denied) begin
            uop_d.xcpt       = 1'b1;
            uop_d.xcpt_cause = i_iq_data.xcpt_cause;
        end else if (pmp_fault) begin
            uop_d.xcpt       = 1'b1;
            uop_d.xcpt_cause = 4'd1;
            uop_d.xcpt_hi    = !lo_denied;           // the second parcel's: mtval = pc + 2
        end else if (c_illegal || !implemented || csr_illegal || priv_illegal || fp_illegal || csr_absent) begin
            uop_d.xcpt       = 1'b1;
            uop_d.xcpt_cause = 4'd2;
        end
        uop_d.rd_wen   = reg_write_ctrl && !uop_d.xcpt;
        if (is_fp) uop_d.rd_wen = fp_rdw && !uop_d.xcpt;
        // a faulting uop goes through the ALU as a no-op for commit to
        // trap on; it must never redirect or touch a CSR
        if (uop_d.xcpt)  uop_d.fu = QV_FU_ALU;
        else if (is_bru) uop_d.fu = QV_FU_BRU;
        else if (is_csr) uop_d.fu = QV_FU_CSR;
        else if (is_mem) uop_d.fu = QV_FU_LSU;
        else if (is_div) uop_d.fu = QV_FU_DIV;
        else if (is_sys) uop_d.fu = QV_FU_SYS;
        else             uop_d.fu = QV_FU_ALU;
        if (is_fp && !uop_d.xcpt) uop_d.fu = qv_fu_e'((fp_ld || fp_st) ? QV_FU_LSU : QV_FU_FPU);
        // a trigger match: Debug Mode entry or breakpoint exception at the head. An action-0 match gives way
        // to a fault marker (fetch fault, illegal instruction), an action-1 one does not.
        uop_d.trig_debug = trig_debug_c;
        uop_d.trig_exc   = trig_exc_c && !uop_d.xcpt;
        if ((uop_d.trig_debug || uop_d.trig_exc) && !(uop_d.fu == QV_FU_SYS && sys_op == QV_SYS_EBREAK)) begin
            uop_d.fu     = QV_FU_ALU;
            uop_d.rd_wen = 1'b0;
            uop_d.rd_fp  = 1'b0;
        end
    end

    logic uop_valid_q;
    uop_t uop_q;

    assign o_iq_pop = i_iq_valid && (!uop_valid_q || i_issue_ready) && !i_flush;
    assign o_valid  = uop_valid_q;
    assign o_uop    = uop_q;

    always_ff @(posedge clk) begin
        if (rst || i_flush) begin
            uop_valid_q <= 1'b0;
        end else if (o_iq_pop) begin
            uop_valid_q <= 1'b1;
            uop_q       <= uop_d;
        end else if (i_issue_ready) begin
            uop_valid_q <= 1'b0;
        end
    end
endmodule
