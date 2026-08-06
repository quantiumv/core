// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: core (multi-cycle RV64I, Wishbone master)
 *
 * Supersedes the single-cycle version: instead of a combinational-read
 * imem/dmem pair private to this module, the core is now the SOLE master
 * on a shared Wishbone bus (see design/wb_addr_decoder.sv,
 * design/wb4_sram.sv, design/uart_tx.sv) -- instruction fetch and data
 * access are both real bus transactions now, and both slaves ack one
 * cycle after being addressed (registered, not combinational). That
 * multi-cycle reality is why this can no longer be single-cycle: a 3-state
 * FSM (S_FETCH / S_EXEC / S_MEM) sequences each instruction instead.
 *
 * decoder/alu/register_file are reused completely unchanged from the
 * single-cycle version -- they were already purely combinational glue
 * with no notion of "cycle" baked in, so nothing about them needed to
 * change. What's new here is entirely the FSM: WHEN the bus is driven,
 * and WHEN the results of that already-combinational logic are allowed to
 * actually commit (register-file write, pc update). See `commit_now`
 * below -- that one signal is the entire difference between this file and
 * the single-cycle version's control-flow shape.
 *
 * Per-instruction flow:
 *  S_FETCH: issue a bus read at pc (dword-aligned -- the bus is 64-bit
 *           wide, so one beat fetches TWO adjacent 32-bit instructions;
 *           pc[2] selects which half this instruction actually is).
 *           Wait for ack, latch the 64-bit line, move to S_EXEC.
 *  S_EXEC:  bus idle. decoder/alu/register_file settle combinationally
 *           off the latched instruction (exactly the single-cycle
 *           version's Decode/Control/Execute/Writeback/Next-PC logic,
 *           verbatim). If this instruction is a load or store, move to
 *           S_MEM without committing anything yet. Otherwise this is the
 *           instruction's last cycle: commit (regfile write + pc update)
 *           on this edge and return to S_FETCH.
 *  S_MEM:   (loads/stores only) issue a bus read or write at alu_result.
 *           Wait for ack; on that edge commit (a load's regfile write
 *           happens HERE, not in S_EXEC, since the loaded value doesn't
 *           exist yet when S_EXEC ends) and return to S_FETCH.
 *
 * Why nothing needs re-latching between S_EXEC and S_MEM: pc doesn't
 * change until commit_now, and the fetched instruction doesn't change
 * until the next S_FETCH's ack -- so every combinational signal derived
 * from them (decoded_instruction, imm_1/imm_2, alu_result, next_pc, ...)
 * is already stable for the instruction's entire multi-cycle lifetime,
 * with no extra latching required beyond the one real latch this design
 * adds (the fetched instruction line itself).
 *
 * Scope: full RV64I base ISA. No M/A/C extensions, no Zicsr/CSRs, no
 * privilege modes, no Sv39, no interrupts/exceptions -- all later
 * milestones. Misaligned access, FENCE, and ECALL are deliberately
 * under-implemented here (see their handling below) for the same reason.
 * wb_err_i is likewise not acted on -- no trap mechanism exists yet for
 * it to feed into.
 *
 * Input ports:
 *  clk: Clock.
 *  rst: Synchronous reset (active high) -- resets pc, FSM state, and
 *       `halted`. Does NOT reset register/memory contents; the ISA
 *       doesn't require it, and real hardware doesn't guarantee it
 *       either (only the reset vector is architecturally defined).
 *
 * Wishbone master port: standard CLASSIC-cycle signal names, written
 * from this module's (the master's) point of view -- `_o` drives the
 * bus, `_i` reads it. Connects to design/wb_addr_decoder.sv's CPU-facing
 * port one-for-one (that module's `_i`/`_o` are the mirror image of
 * these, as expected for a master/slave pair).
 */
module core (
    input logic clk,
    input logic rst,

    output logic [31:0] wb_addr_o,
    output logic [63:0] wb_dat_o,
    input  logic [63:0] wb_dat_i,
    output logic [7:0]  wb_sel_o,
    output logic        wb_we_o,
    output logic        wb_cyc_o,
    output logic        wb_stb_o,
    input  logic        wb_ack_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic        wb_err_i
    /* verilator lint_on UNUSEDSIGNAL */
);

    /* --------------------------------------------------------------- *
     * FSM state
     * --------------------------------------------------------------- */

    typedef enum logic [1:0] {
        S_FETCH,
        S_EXEC,
        S_MEM
    } state_t;

    state_t state;

    logic [(`WORD_SIZE - 1):0] pc;
    logic [(`WORD_SIZE - 1):0] next_pc;

    /*
     * Forward-declared here (driven later, in the Control unit and
     * PC/halt sections respectively) purely because Icarus Verilog wants
     * a signal declared before its first use, textually -- unlike the
     * rest of this file, mem_phase_needed/wb_master_drive genuinely need
     * to reference them earlier in the file than where they're driven.
     */
    logic is_load, is_store;
    logic halted;

    /*
     * commit_now: the single edge, per instruction, where the
     * register-file write and the pc update are allowed to actually
     * happen. Every other cycle of an instruction's multi-cycle lifetime
     * (bus wait states, the settle cycle itself) must NOT commit, even
     * though decoder/alu outputs are sitting there fully formed the
     * whole time -- reg_write/next_pc are free-running combinational
     * signals with no notion of "am I allowed to land yet", so this is
     * the one gate that turns "instruction is decoded" into "instruction
     * has retired". Non-memory instructions retire at the end of
     * S_EXEC; loads/stores retire when S_MEM's bus transaction acks.
     */
    wire mem_phase_needed = is_load || is_store;
    wire commit_now = (state == S_EXEC && !mem_phase_needed)
                    || (state == S_MEM && wb_ack_i);

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH;
        end else begin
            case (state)
                S_FETCH: if (wb_ack_i) state <= S_EXEC;
                S_EXEC:  state <= state_t'(mem_phase_needed ? S_MEM : S_FETCH);
                S_MEM:   if (wb_ack_i) state <= S_FETCH;
                default: state <= S_FETCH;
            endcase
        end
    end

    /* --------------------------------------------------------------- *
     * Fetch
     * --------------------------------------------------------------- */

    /*
     * The bus is 64-bit wide and word-addressed (low 3 address bits
     * unused, same convention as wb4_sram.sv/wb_addr_decoder.sv), but
     * instructions are 32-bit -- one fetch beat brings in two of them.
     * pc[2] (always a real address bit for a 4-byte-aligned pc) picks
     * which half is the one actually being executed; pc[1:0] are always
     * 0 and play no role here.
     */
    logic [63:0] instr_line_q;
    always_ff @(posedge clk) begin
        if (state == S_FETCH && wb_ack_i)
            instr_line_q <= wb_dat_i;
    end

    logic [(`INSTR_SIZE - 1):0] instruction;
    assign instruction = pc[2] ? instr_line_q[63:32] : instr_line_q[31:0];

    /*
     * Dword-aligned fetch address, precomputed as a plain wire rather
     * than inline inside wb_master_drive's always_comb below -- same
     * "Icarus doesn't fully support constant selects inside always_*
     * processes" reason as everywhere else this pattern appears in this
     * file.
     */
    wire [31:0] fetch_addr = {pc[31:3], 3'b0};

    /* --------------------------------------------------------------- *
     * Decode
     * --------------------------------------------------------------- */

    logic [(`L2_REG_FILE_SIZE - 1):0] read_gpr_A_sel, read_gpr_B_sel;
    logic [(`WORD_SIZE - 1):0]        read_gpr_A_data, read_gpr_B_data;
    logic [(`INSTR_CODE_SIZE - 1):0]  decoded_instruction;
    logic [(`WORD_SIZE - 1):0]        imm_1, imm_2;
    logic [(`B_IMM_SIZE - 1):0]       imm_3_or_dest_addr;

    /*
     * decoder <-> register_file looks port-level circular (decoder's
     * *_sel outputs feed regfile's read ports; regfile's read *_data
     * outputs feed back into decoder's i_read_gpr_*_data inputs, which
     * decoder uses to produce o_imm_1/o_imm_2) but it isn't a real
     * combinational cycle: the *_sel outputs depend ONLY on
     * i_instruction inside decoder, never on the data that comes back.
     * It settles in zero simulated time as a plain feedforward chain --
     * and since `instruction` is latched (stable for the whole
     * instruction), so is everything downstream of it here.
     */
    decoder decoder0 (
        .i_instruction(instruction),
        .i_instruction_address(pc),
        /*
         * Explicitly connected to nothing (not omitted) -- it's just a
         * passthrough of i_instruction_address (i.e. pc), nothing
         * downstream needs a second copy of it. Empty parens rather than
         * leaving the line out entirely so lint tools see this as
         * deliberate rather than a possibly-forgotten connection.
         */
        /* verilator lint_off PINCONNECTEMPTY */
        .o_instruction_address(),
        /* verilator lint_on PINCONNECTEMPTY */
        .o_read_gpr_A_sel(read_gpr_A_sel),
        .i_read_gpr_A_data(read_gpr_A_data),
        .o_read_gpr_B_sel(read_gpr_B_sel),
        .i_read_gpr_B_data(read_gpr_B_data),
        .o_decoded_instruction(decoded_instruction),
        .o_imm_1(imm_1),
        .o_imm_2(imm_2),
        .o_imm_3_or_dest_addr(imm_3_or_dest_addr)
    );

    logic                       reg_write;
    logic [(`WORD_SIZE - 1):0]  reg_write_data;

    register_file regfile0 (
        .i_clk(clk),
        .i_read_gpr_A_sel(read_gpr_A_sel),
        .o_read_gpr_A_data(read_gpr_A_data),
        .i_read_gpr_B_sel(read_gpr_B_sel),
        .o_read_gpr_B_data(read_gpr_B_data),
        .i_load_gpr(reg_write),
        /*
         * imm_3_or_dest_addr means two unrelated things depending on
         * instruction type (see decoder.sv's port doc for the full
         * story): a signed S/B-type offset, or a plain 5-bit rd index
         * (R/I/U/J-type). Here we use ONLY the low 5 bits, as an
         * unsigned register index -- correct for the R/I/U/J case, and
         * harmless for S/B-type (stores and branches never assert
         * reg_write, so regfile0 ignores this value in that case
         * regardless of what garbage sign bits sit above it). Getting
         * this confused with the SIGNED interpretation (imm3_sext,
         * below) is the single easiest mistake to make with this port --
         * small positive immediates look identical either way, so a
         * quick smoke test won't catch it, only a negative-offset test
         * will (see core_load_store_tb.sv).
         */
        .i_load_gpr_sel(imm_3_or_dest_addr[(`L2_REG_FILE_SIZE - 1):0]),
        .i_load_gpr_data(reg_write_data)
    );

    /* Sign-extended S/B-type offset -- see the comment above. */
    wire [(`WORD_SIZE - 1):0] imm3_sext =
        {{(`WORD_SIZE - `B_IMM_SIZE){imm_3_or_dest_addr[`B_IMM_SIZE - 1]}}, imm_3_or_dest_addr};

    /* --------------------------------------------------------------- *
     * Control unit
     * --------------------------------------------------------------- */

    wire is_auipc  = (decoded_instruction == `INSTR_CODE(AUIPC));
    wire is_jal    = (decoded_instruction == `INSTR_CODE(JAL));
    wire is_jalr   = (decoded_instruction == `INSTR_CODE(JALR));
    wire is_ebreak = (decoded_instruction == `INSTR_CODE(EBREAK));

    /*
     * ADDW/SUBW/ADDIW reuse the plain ADD/SUB ALU ops on full 64-bit
     * operands (bit-identical to a native 32-bit add/sub in the low 32
     * bits -- two's-complement addition is modular arithmetic) and get
     * truncated+re-signed HERE, centrally, in the write-back mux below.
     * SLLW/SRLW/SRAW(+I variants) can't take that shortcut -- a shift is
     * NOT bit-identical across widths (wrong-width operand, bits enter
     * from the wrong end) -- so those instead use dedicated 32-bit-wide
     * ALU ops (see alu_ops.sv) whose output is already the final,
     * correctly-extended 64-bit value; they fall through the write-back
     * mux untouched, same as any ordinary ALU result.
     */
    wire is_word_arith = (decoded_instruction == `INSTR_CODE(ADDW))
                       || (decoded_instruction == `INSTR_CODE(SUBW))
                       || (decoded_instruction == `INSTR_CODE(ADDIW));

    logic [(`ALU_OPSIZE - 1):0] alu_op;
    always_comb begin: alu_op_sel
        case (decoded_instruction)
            `INSTR_CODE(ADDI), `INSTR_CODE(ADD),
            `INSTR_CODE(ADDIW), `INSTR_CODE(ADDW),
            /*
             * Also every instruction that uses the ALU purely as an
             * adder rather than for its "own" arithmetic meaning: LUI
             * (o_imm_2=0 from the decoder, so ADD is a passthrough of
             * o_imm_1), AUIPC (pc + immediate, via the operand-A mux
             * below), JALR and every load/store (base + offset address
             * calculation).
             */
            `INSTR_CODE(LUI), `INSTR_CODE(AUIPC), `INSTR_CODE(JALR),
            `INSTR_CODE(LB), `INSTR_CODE(LH), `INSTR_CODE(LW),
            `INSTR_CODE(LBU), `INSTR_CODE(LHU), `INSTR_CODE(LWU), `INSTR_CODE(LD),
            `INSTR_CODE(SB), `INSTR_CODE(SH), `INSTR_CODE(SW), `INSTR_CODE(SD):
                alu_op = `ADD;

            `INSTR_CODE(SUB), `INSTR_CODE(SUBW):
                alu_op = `SUB;

            `INSTR_CODE(SLTI), `INSTR_CODE(SLT):   alu_op = `SLT;
            `INSTR_CODE(SLTIU), `INSTR_CODE(SLTU): alu_op = `SLTU;
            `INSTR_CODE(XORI), `INSTR_CODE(XOR):   alu_op = `XOR;
            `INSTR_CODE(ORI), `INSTR_CODE(OR):     alu_op = `OR;
            `INSTR_CODE(ANDI), `INSTR_CODE(AND):   alu_op = `AND;

            `INSTR_CODE(SLLI), `INSTR_CODE(SLL): alu_op = `SLL;
            `INSTR_CODE(SRLI), `INSTR_CODE(SRL): alu_op = `SRL;
            `INSTR_CODE(SRAI), `INSTR_CODE(SRA): alu_op = `SRA;

            `INSTR_CODE(SLLIW), `INSTR_CODE(SLLW): alu_op = `SLLW;
            `INSTR_CODE(SRLIW), `INSTR_CODE(SRLW): alu_op = `SRLW;
            `INSTR_CODE(SRAIW), `INSTR_CODE(SRAW): alu_op = `SRAW;

            /*
             * Zicsr: no new ALU ops needed (see the operand-mux comments
             * above for the operand-B redirect each of these relies on).
             */
            `INSTR_CODE(CSRRS), `INSTR_CODE(CSRRSI): alu_op = `OR;
            `INSTR_CODE(CSRRC), `INSTR_CODE(CSRRCI): alu_op = `AND;
            `INSTR_CODE(CSRRW), `INSTR_CODE(CSRRWI): alu_op = `ADD;

            /*
             * Branches/JAL/FENCE/ECALL/EBREAK/INVALID don't use
             * alu_result for anything (branches have their own
             * comparator below; JAL's target/link come from the PC
             * adder and pc_plus_4 directly) -- alu_op is a don't-care
             * for these, defaulted to ADD purely so alu_op always has a
             * defined value.
             */
            default: alu_op = `ADD;
        endcase
    end: alu_op_sel

    logic [1:0] mem_size;
    logic load_signed;
    always_comb begin: mem_control
        is_load = 1'b0;
        is_store = 1'b0;
        mem_size = 2'b10;
        load_signed = 1'b0;
        case (decoded_instruction)
            `INSTR_CODE(LB):  begin is_load = 1'b1; mem_size = 2'b00; load_signed = 1'b1; end
            `INSTR_CODE(LBU): begin is_load = 1'b1; mem_size = 2'b00; load_signed = 1'b0; end
            `INSTR_CODE(LH):  begin is_load = 1'b1; mem_size = 2'b01; load_signed = 1'b1; end
            `INSTR_CODE(LHU): begin is_load = 1'b1; mem_size = 2'b01; load_signed = 1'b0; end
            `INSTR_CODE(LW):  begin is_load = 1'b1; mem_size = 2'b10; load_signed = 1'b1; end
            `INSTR_CODE(LWU): begin is_load = 1'b1; mem_size = 2'b10; load_signed = 1'b0; end
            `INSTR_CODE(LD):  begin is_load = 1'b1; mem_size = 2'b11; load_signed = 1'b1; end
            `INSTR_CODE(SB):  begin is_store = 1'b1; mem_size = 2'b00; end
            `INSTR_CODE(SH):  begin is_store = 1'b1; mem_size = 2'b01; end
            `INSTR_CODE(SW):  begin is_store = 1'b1; mem_size = 2'b10; end
            `INSTR_CODE(SD):  begin is_store = 1'b1; mem_size = 2'b11; end
            default: ;
        endcase
    end: mem_control

    /*
     * reg_write: computed by excluding the SHORT list of instructions
     * that don't write rd, rather than enumerating the long list that
     * does -- fewer places to accidentally miss an entry when a future
     * milestone adds more instructions. Gated by commit_now (see its own
     * comment above) so this only actually reaches regfile0 on the one
     * edge each instruction is allowed to retire, not throughout the
     * whole multi-cycle window it happens to be decoded.
     */
    logic reg_write_ctrl;
    always_comb begin: reg_write_control
        case (decoded_instruction)
            `INSTR_CODE(SB), `INSTR_CODE(SH), `INSTR_CODE(SW), `INSTR_CODE(SD),
            `INSTR_CODE(BEQ), `INSTR_CODE(BNE), `INSTR_CODE(BLT),
            `INSTR_CODE(BGE), `INSTR_CODE(BLTU), `INSTR_CODE(BGEU),
            `INSTR_CODE(FENCE), `INSTR_CODE(ECALL), `INSTR_CODE(EBREAK),
            `INSTR_CODE(INVALID):
                reg_write_ctrl = 1'b0;
            default:
                reg_write_ctrl = 1'b1;
        endcase
    end: reg_write_control
    assign reg_write = reg_write_ctrl && commit_now;

    /*
     * Zicsr classification. mem_control/reg_write_control above need no
     * new arms for these six codes: mem_control's default (is_load=0,
     * is_store=0) already applies, so a CSR instruction retires in a
     * single S_EXEC cycle like any ordinary ALU op; reg_write_control's
     * default (reg_write_ctrl = 1'b1) already applies too, so rd gets
     * written same as any other non-excluded instruction.
     */
    wire is_csrrw  = (decoded_instruction == `INSTR_CODE(CSRRW));
    wire is_csrrs  = (decoded_instruction == `INSTR_CODE(CSRRS));
    wire is_csrrc  = (decoded_instruction == `INSTR_CODE(CSRRC));
    wire is_csrrwi = (decoded_instruction == `INSTR_CODE(CSRRWI));
    wire is_csrrsi = (decoded_instruction == `INSTR_CODE(CSRRSI));
    wire is_csrrci = (decoded_instruction == `INSTR_CODE(CSRRCI));
    wire is_csr_rw = is_csrrw || is_csrrwi;
    wire is_csr_rs = is_csrrs || is_csrrsi;
    wire is_csr_rc = is_csrrc || is_csrrci;
    wire is_csr    = is_csr_rw || is_csr_rs || is_csr_rc;

    /*
     * Write-suppress condition, per spec: CSRRS/CSRRC suppress the write
     * when rs1's FIELD is x0 (read_gpr_A_sel == 0) -- a register OTHER
     * than x0 that happens to hold value 0 must still attempt the write,
     * so this must NOT be checked as imm_1 == 0 (the runtime value).
     * CSRRSI/CSRRCI have no such field/value distinction -- uimm IS a
     * literal -- so imm_1 == 0 (which is where the decoder parks the
     * zero-extended uimm) is correct there.
     */
    wire csr_write_suppress = (is_csrrs || is_csrrc)   ? (read_gpr_A_sel == 0) :
                               (is_csrrsi || is_csrrci) ? (imm_1 == 0)         :
                                                           1'b0;

    /*
     * Forward-declared here, same reason is_load/is_store/halted are
     * (see the comment near the top of this file): csr_rdata is
     * referenced below in the operand muxes, textually before csr_file0
     * -- the instance that actually drives it -- is declared (csr_file0
     * has to come after alu0, since its write data is alu_result).
     */
    logic [(`WORD_SIZE - 1):0] csr_rdata;
    wire csr_we = is_csr && commit_now && !csr_write_suppress;

    /* --------------------------------------------------------------- *
     * Execute
     * --------------------------------------------------------------- */

    /*
     * AUIPC needs pc+imm, but the decoder parks the U-immediate on
     * o_imm_1 (the "A slot") for both LUI and AUIPC, with o_imm_2
     * hardwired to 0 (OUTPUT_U_TYPE_INSTR). LUI rides that as-is: A =
     * imm_1, B = imm_2 (0), giving imm+0. AUIPC instead needs pc as one
     * addend and the immediate as the other, so it swaps BOTH operands:
     * A becomes pc, and B is redirected to imm_1 to recover the
     * immediate that A just displaced -- using the default imm_2 here
     * (0) would silently compute pc+0 and drop the immediate entirely.
     */
    /*
     * CSRRS/CSRRC redirect A to the CSR's CURRENT value -- "OR/AND a
     * mask into/out of the CSR" reads the CSR, not rs1/uimm -- same
     * operand-redirect idea AUIPC already uses above, just sourced from
     * csr_rdata instead of pc. CSRRW/CSRRWI need no redirect: their new
     * value IS rs1/uimm, which is already sitting on imm_1 by default.
     */
    wire [(`WORD_SIZE - 1):0] alu_operand_a = (is_csr_rs || is_csr_rc) ? csr_rdata :
                                               is_auipc                 ? pc        :
                                                                          imm_1;
    /*
     * CSRRS ORs the rs1/uimm mask (already on imm_1) into the CSR -- B =
     * imm_1, paired with alu_op_sel's OR arm below. CSRRC ANDs with the
     * bitwise-complement of that same mask -- B = ~imm_1, paired with
     * AND (pre-inverting the operand here instead of adding a dedicated
     * "AND-NOT" ALU op, same trick as AUIPC's operand redirect above).
     * CSRRW/CSRRWI overwrite the CSR outright -- B forced to 0, paired
     * with ADD (the same passthrough trick LUI's ADD-with-B=0 already
     * uses) -- so alu_result ends up uniformly "the new CSR value" for
     * all 6 variants, and csr_file0's write port needs no extra mux.
     */
    wire [(`WORD_SIZE - 1):0] alu_operand_b = is_store  ? imm3_sext      :
                                               is_auipc  ? imm_1          :
                                               is_csr_rs ? imm_1          :
                                               is_csr_rc ? ~imm_1         :
                                               is_csr_rw ? `WORD_SIZE'(0) :
                                                            imm_2;

    logic [(`WORD_SIZE - 1):0] alu_result;
    alu alu0 (
        .i_operand_A(alu_operand_a),
        .i_operation(alu_op),
        .i_operand_B(alu_operand_b),
        .o_result(alu_result)
    );

    /*
     * csr_file0: instantiated here, after alu0 rather than up with the
     * rest of the new Zicsr wires in the Control unit section above --
     * its write data is alu_result, which by construction (see the
     * operand-mux/alu_op_sel comments above) is uniformly "the new CSR
     * value" for all 6 variants, and alu_result doesn't exist until
     * alu0 above is declared.
     */
    csr_file csr_file0 (
        .i_clk(clk),
        .i_rst(rst),
        .i_csr_addr(imm_2[(`CSR_ADDR_SIZE - 1):0]),
        .o_csr_rdata(csr_rdata),
        .i_csr_we(csr_we),
        .i_csr_wdata(alu_result),
        .i_instr_retired(commit_now)
    );

    /*
     * Branch comparator: NOT routed through alu0. alu_ops.sv has no
     * equality/inequality op, and each branch type needs a different
     * comparison (equality, signed, unsigned) -- easier as its own small
     * block than trying to force it through a shared single-op ALU
     * interface. default: 1'b0 doubles as "this instruction isn't a
     * branch at all", so the next-PC mux below needs no separate
     * is_branch gate.
     */
    logic take_branch;
    always_comb begin: branch_comparator
        case (decoded_instruction)
            `INSTR_CODE(BEQ):  take_branch = (imm_1 == imm_2);
            `INSTR_CODE(BNE):  take_branch = (imm_1 != imm_2);
            `INSTR_CODE(BLT):  take_branch = ($signed(imm_1) <  $signed(imm_2));
            `INSTR_CODE(BGE):  take_branch = ($signed(imm_1) >= $signed(imm_2));
            `INSTR_CODE(BLTU): take_branch = (imm_1 < imm_2);
            `INSTR_CODE(BGEU): take_branch = (imm_1 >= imm_2);
            default:           take_branch = 1'b0;
        endcase
    end: branch_comparator

    /* --------------------------------------------------------------- *
     * Memory
     * --------------------------------------------------------------- */

    /*
     * alu_result does triple duty here: it's "the ALU's answer" for
     * every non-memory instruction, "the memory address" for
     * loads/stores (base register + offset, computed by the same adder
     * via the operand muxing above), AND the source of the bus's
     * dword-aligned address plus the byte-lane shift amount below --
     * deliberate reuse of one datapath, not a coincidence.
     *
     * The bus (see wb4_sram.sv/uart_tx.sv) is word-granular: address
     * bits [2:0] aren't decoded by either slave, and sub-dword access
     * width instead comes from which of the 8 sel_o lanes are asserted.
     * So a byte/half/word access needs its size turned into a lane mask,
     * shifted into position by the address's low 3 bits -- the same
     * mask-and-shift technique wb4_sram.sv uses for its own byte-enable
     * writes.
     */
    wire [7:0] mem_size_mask = (mem_size == 2'b00) ? 8'b0000_0001 :
                                (mem_size == 2'b01) ? 8'b0000_0011 :
                                (mem_size == 2'b10) ? 8'b0000_1111 :
                                                       8'b1111_1111;
    wire [7:0] mem_sel = mem_size_mask << alu_result[2:0];

    /* Dword-aligned memory address -- same precompute-outside-always_comb reason as fetch_addr above. */
    wire [31:0] mem_addr = {alu_result[31:3], 3'b0};

    /* Store data, pre-shifted into the byte lane(s) it'll land in. */
    wire [(`WORD_SIZE - 1):0] mem_wdata = imm_2 << (alu_result[2:0] * 8);

    /* Read response, shifted back down so the wanted byte(s) start at bit 0. */
    wire [(`WORD_SIZE - 1):0] mem_rdata_shifted = wb_dat_i >> (alu_result[2:0] * 8);

    /*
     * Precomputed slices, not inline inside load_format's case statement
     * below -- Icarus Verilog doesn't fully support constant selects
     * inside always_* processes (same reason as alu.sv's shamt_masked).
     */
    wire [7:0]  load_byte  = mem_rdata_shifted[7:0];
    wire [15:0] load_half  = mem_rdata_shifted[15:0];
    wire [31:0] load_word  = mem_rdata_shifted[31:0];
    /* Sign bits, precomputed too -- same reason (also used inside a replication below). */
    wire load_byte_sign = load_byte[7];
    wire load_half_sign = load_half[15];
    wire load_word_sign = load_word[31];

    logic [(`WORD_SIZE - 1):0] load_data;
    always_comb begin: load_format
        case (mem_size)
            2'b00: load_data = load_signed ? {{56{load_byte_sign}}, load_byte}
                                            : {56'b0, load_byte};
            2'b01: load_data = load_signed ? {{48{load_half_sign}}, load_half}
                                            : {48'b0, load_half};
            2'b10: load_data = load_signed ? {{32{load_word_sign}}, load_word}
                                            : {32'b0, load_word};
            default: load_data = mem_rdata_shifted; // 2'b11: doubleword, no extension needed
        endcase
    end: load_format

    /* --------------------------------------------------------------- *
     * Wishbone master: bus driving
     * --------------------------------------------------------------- */

    /*
     * Idle by default (every field), overridden per-state below -- keeps
     * this a clean combinational mux with no inferred latches, same
     * defaults-then-case idiom already used for mem_control/
     * reg_write_control above. S_EXEC drives nothing: the bus is only
     * needed to fetch (S_FETCH) or to access memory (S_MEM), never
     * during the settle-and-decode cycle in between.
     *
     * Both S_FETCH and S_MEM additionally gate cyc_o/stb_o with
     * !wb_ack_i, NOT just `state == S_*` -- this is load-bearing, not
     * decoration. `state` only updates on the NEXT clock edge after
     * wb_ack_i is observed (see the state always_ff below), so for the
     * entire cycle in between -- from the moment the slave's registered
     * ack_o first becomes 1 to the edge core.sv's FSM actually reacts to
     * it -- cyc_o/stb_o would otherwise still read as asserted. A slave
     * that simply does `if (cyc_i && stb_i) <act once, ack>` (both
     * wb4_sram.sv and uart_tx.sv do exactly this, and correctly so --
     * nothing about the spec obligates a slave to guess whether a
     * still-asserted cyc/stb is a new request or the master being slow
     * to notice the old one) would then see cyc/stb still high on that
     * extra cycle and serve the SAME request a second time. Found via
     * this exact symptom: the UART printed "HH" for a single-byte write.
     * Gating with !wb_ack_i drops cyc_o/stb_o combinationally the moment
     * ack_i is observed, so the slave sees the request deasserted before
     * it would ever re-fire -- standard Wishbone master practice, and
     * the same root cause (not the same fix -- that one patched a
     * testbench's own master-role loop) as the wb_cycle ack-timing bug
     * in wb4_sram_tb.sv/uart_tx_tb.sv.
     */
    always_comb begin: wb_master_drive
        wb_cyc_o  = 1'b0;
        wb_stb_o  = 1'b0;
        wb_we_o   = 1'b0;
        wb_addr_o = 32'b0;
        wb_dat_o  = 64'b0;
        wb_sel_o  = 8'b0;
        case (state)
            S_FETCH: begin
                /*
                 * Once halted, never issue another fetch -- see the
                 * halt-latch comment below for why parking here (rather
                 * than, say, forcing state to hold) is sufficient to
                 * freeze the whole core.
                 */
                if (!halted && !wb_ack_i) begin
                    wb_cyc_o  = 1'b1;
                    wb_stb_o  = 1'b1;
                    wb_addr_o = fetch_addr;
                    wb_sel_o  = 8'hFF; // don't-care for a read; full line for clarity
                end
            end
            S_MEM: begin
                if (!wb_ack_i) begin
                    wb_cyc_o  = 1'b1;
                    wb_stb_o  = 1'b1;
                    wb_we_o   = is_store;
                    wb_addr_o = mem_addr;
                    wb_sel_o  = mem_sel;
                    wb_dat_o  = mem_wdata;
                end
            end
            default: ; // S_EXEC: bus idle
        endcase
    end: wb_master_drive

    /* --------------------------------------------------------------- *
     * Writeback
     * --------------------------------------------------------------- */

    wire [(`WORD_SIZE - 1):0] pc_plus_4 = pc + `WORD_SIZE'(4);

    /* See the is_word_arith comment above for why only some *W ops need this. */
    wire [(`WORD_SIZE - 1):0] alu_result_w_trunc = {{32{alu_result[31]}}, alu_result[31:0]};

    /*
     * Zicsr writes the OLD CSR value to rd, for all 6 variants (per
     * spec) -- csr_rdata was captured combinationally off the CSR's
     * pre-write contents this same cycle, same "read before the
     * same-edge overwrite" principle as every other read-then-write
     * already in this design (e.g. the regfile's own read-before-write).
     */
    assign reg_write_data = is_load               ? load_data :
                             (is_jal || is_jalr)   ? pc_plus_4 :
                             is_word_arith         ? alu_result_w_trunc :
                             is_csr                ? csr_rdata :
                                                      alu_result; // ALU ops, LUI, AUIPC, *W shifts

    /* --------------------------------------------------------------- *
     * Next PC
     * --------------------------------------------------------------- */

    /* JAL's immediate lands on imm_1 (OUTPUT_J_TYPE_INSTR); branches' on imm3_sext. */
    wire [(`WORD_SIZE - 1):0] pc_rel_offset = is_jal ? imm_1 : imm3_sext;
    wire [(`WORD_SIZE - 1):0] pc_rel_target = pc + pc_rel_offset;

    /*
     * Per spec, JALR's target is (rs1 + sext(imm)) with bit 0 forced to
     * 0 -- guarantees an even target regardless of whether rs1+imm
     * happens to be odd. Only the JUMP TARGET's LSB is cleared here; the
     * link value written back to rd (pc_plus_4, above) is always
     * unmodified.
     */
    wire [(`WORD_SIZE - 1):0] jalr_target = {alu_result[63:1], 1'b0};

    assign next_pc = (is_jal || take_branch) ? pc_rel_target :
                      is_jalr                 ? jalr_target   :
                                                 pc_plus_4;

    /* --------------------------------------------------------------- *
     * PC register / halt latch
     * --------------------------------------------------------------- */

    /*
     * EBREAK latches `halted` and freezes pc -- the only piece of
     * "extra" state in this design, beyond pc/state/instr_line_q. Both
     * commit only on commit_now (EBREAK is never a load/store, so it
     * always retires at the end of S_EXEC). pc is deliberately excluded
     * from advancing on the SAME edge halted is set (`!is_ebreak` below)
     * -- otherwise pc would jump past EBREAK on the very edge that's
     * supposed to freeze it. After that edge, state parks in S_FETCH
     * forever (the bus-driving block above stops issuing fetches once
     * halted), so commit_now can never become true again and both
     * registers stay frozen with no further gating needed.
     *
     * Testbenches watch `halted` via a hierarchical reference (e.g.
     * dut.halted) to know when a test program has finished running,
     * without guessing a cycle count.
     */
    always_ff @(posedge clk) begin
        if (rst)
            halted <= 1'b0;
        else if (commit_now && is_ebreak)
            halted <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst)
            pc <= '0;
        else if (commit_now && !is_ebreak)
            pc <= next_pc;
    end

endmodule
