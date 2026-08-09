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
 * multi-cycle reality is why this can no longer be single-cycle: a 4-state
 * FSM (S_FETCH / S_EXEC / S_MEM / S_AMO_WRITE) sequences each instruction
 * instead.
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
 *           exist yet when S_EXEC ends) and return to S_FETCH -- UNLESS
 *           this is one of the 9 read-modify-write AMO ops, in which case
 *           this ack was only the READ half and next state is
 *           S_AMO_WRITE instead.
 *  S_AMO_WRITE: (the 9 read-modify-write AMO ops only) issue a bus write
 *           at the SAME address S_MEM just read from, using a value
 *           computed from the just-captured old memory value and rs2.
 *           Wait for ack; commit (both the memory write's effect and
 *           rd = the OLD value) happens HERE, not in S_MEM.
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
        S_MEM,
        S_AMO_WRITE
    } state_t;

    state_t state;

    /*
     * Current privilege level (U/S/M privilege-mode milestone). Standard
     * RISC-V encoding -- bare local enum, no defaults.sv entry, same
     * precedent as state_t immediately above.
     */
    typedef enum logic [1:0] {
        PRIV_U = 2'b00,
        PRIV_S = 2'b01,
        PRIV_M = 2'b11
    } priv_t;

    priv_t current_priv;

    logic [(`WORD_SIZE - 1):0] pc;
    logic [(`WORD_SIZE - 1):0] next_pc;

    /*
     * Forward-declared here (driven later, in the Control unit and
     * PC/halt sections respectively) purely because Icarus Verilog wants
     * a signal declared before its first use, textually -- unlike the
     * rest of this file, mem_phase_needed/wb_master_drive genuinely need
     * to reference them earlier in the file than where they're driven.
     * div_stall joins them for the same reason -- commit_now/the S_EXEC
     * transition below need it, but it isn't actually driven until the
     * "M extension: divide" section, much further down. is_amo_rmw joins
     * them for the identical reason (A extension) -- driven later via a
     * plain assign, never redeclared as `wire ... = ...` at its point of
     * computation.
     *
     * amo_rdata_q/amo_addr_q/amo_sel_q are forward-declared for a
     * different reason: they're REGISTERS (driven by an always_ff),
     * needed by alu_operand_a/b (Execute, textually early) but only
     * correctly drivable after Memory's load_data/mem_addr/mem_sel exist
     * (textually late) -- same "declare early, drive late" split
     * csr_rdata/medeleg_w already use.
     */
    logic is_load, is_store;
    logic halted;
    logic div_stall;
    logic is_amo_rmw;
    logic [(`WORD_SIZE - 1):0] amo_rdata_q;
    logic [31:0] amo_addr_q;
    logic [7:0]  amo_sel_q;

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
     *
     * div_stall generalizes this same idea to the one OTHER thing that
     * can now make a non-memory instruction take more than a single
     * S_EXEC cycle: an in-flight divide (see "M extension: divide"
     * below, and design/divider.sv's own header -- this is the first
     * variable-latency non-memory instruction this core has ever had).
     * div_stall/is_div_family are declared further down, in the M
     * extension section, but referenced here -- same forward-reference
     * pattern is_load/is_store already use from this exact spot.
     * mem_phase_needed and div_stall can never both be true together (a
     * single decoded instruction can't be both a divide and a load/store),
     * so there's no ordering/priority to arbitrate between them below.
     */
    wire mem_phase_needed = is_load || is_store;
    /*
     * commit_now, extended for the A extension: an AMO op's
     * mem_phase_needed=1 now spans TWO sequential bus transactions
     * (S_MEM's read, then S_AMO_WRITE's write), not one -- S_MEM's ack
     * must NOT commit for an AMO op (it only ends the read half), only
     * S_AMO_WRITE's ack does. LR/SC/plain loads/stores are unaffected:
     * is_amo_rmw is false for all of them, so the new `&& !is_amo_rmw`
     * term is a no-op and they still commit at S_MEM exactly as before.
     */
    wire commit_now = (state == S_EXEC && !mem_phase_needed && !div_stall)
                    || (state == S_MEM && wb_ack_i && !is_amo_rmw)
                    || (state == S_AMO_WRITE && wb_ack_i);

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH;
        end else begin
            case (state)
                S_FETCH:     if (wb_ack_i) state <= S_EXEC;
                S_EXEC:      state <= state_t'(mem_phase_needed ? S_MEM : (div_stall ? S_EXEC : S_FETCH));
                S_MEM:       if (wb_ack_i) state <= state_t'(is_amo_rmw ? S_AMO_WRITE : S_FETCH);
                S_AMO_WRITE: if (wb_ack_i) state <= S_FETCH;
                default:     state <= S_FETCH;
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
    /*
     * fetch_paddr: named indirection point for a future Sv39 MMU stage.
     * Today a pure passthrough (pc IS the physical address -- no
     * translation exists yet); when Sv39 lands, only this wire's RHS
     * needs to change (e.g. to a page-table-walker's translated
     * output), with no restructuring of the surrounding FSM/bus-driving
     * logic below. (`instruction`'s pc[2] half-select above is
     * deliberately left as raw pc -- it's a page-OFFSET bit, always
     * identity-mapped even under Sv39, so there's nothing for
     * translation to ever change there.)
     *
     * Deliberately WORD_SIZE-wide even though only bits[31:3] are
     * consumed today (this core's physical address space is 32 bits) --
     * a real translated address should be able to occupy the full seam
     * width without a resize, so the unused bits are structural, not an
     * oversight.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    wire [(`WORD_SIZE - 1):0] fetch_paddr = pc;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] fetch_addr = {fetch_paddr[31:3], 3'b0};

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
    /*
     * MULW joins this same group for the same reason ADDW/SUBW do: a
     * 32x32-truncated-to-32 product is bit-identical regardless of what's
     * in the operands' upper 32 bits (multiplication mod 2^32 doesn't
     * depend on that), so MULW reuses MUL wholesale and just needs the
     * same central truncate+resign as ADDW/SUBW/ADDIW -- see
     * design/defaults/alu_ops.sv's own header comment on MUL for the
     * full argument. DIVW/DIVUW/REMW/REMUW do NOT belong here -- see the
     * "M extension: divide" section below for why they need their own
     * (non-ALU) truncation path instead.
     */
    wire is_word_arith = (decoded_instruction == `INSTR_CODE(ADDW))
                       || (decoded_instruction == `INSTR_CODE(SUBW))
                       || (decoded_instruction == `INSTR_CODE(ADDIW))
                       || (decoded_instruction == `INSTR_CODE(MULW));

    /*
     * A extension: LR/SC/AMO classification. Placed here, before
     * alu_op_sel/mem_control below -- load-bearing, not stylistic:
     * mem_control's SC arm needs sc_success, so this whole block must be
     * textually established first (unlike CSR's own classification,
     * which comes AFTER mem_control today, since nothing in mem_control
     * needs it).
     */
    wire is_lr_w = (decoded_instruction == `INSTR_CODE(LR_W));
    wire is_lr_d = (decoded_instruction == `INSTR_CODE(LR_D));
    wire is_lr   = is_lr_w || is_lr_d;

    wire is_sc_w = (decoded_instruction == `INSTR_CODE(SC_W));
    wire is_sc_d = (decoded_instruction == `INSTR_CODE(SC_D));
    wire is_sc   = is_sc_w || is_sc_d;

    wire is_amoswap_w = (decoded_instruction == `INSTR_CODE(AMOSWAP_W));
    wire is_amoswap_d = (decoded_instruction == `INSTR_CODE(AMOSWAP_D));
    wire is_amoadd_w  = (decoded_instruction == `INSTR_CODE(AMOADD_W));
    wire is_amoadd_d  = (decoded_instruction == `INSTR_CODE(AMOADD_D));
    wire is_amoxor_w  = (decoded_instruction == `INSTR_CODE(AMOXOR_W));
    wire is_amoxor_d  = (decoded_instruction == `INSTR_CODE(AMOXOR_D));
    wire is_amoor_w   = (decoded_instruction == `INSTR_CODE(AMOOR_W));
    wire is_amoor_d   = (decoded_instruction == `INSTR_CODE(AMOOR_D));
    wire is_amoand_w  = (decoded_instruction == `INSTR_CODE(AMOAND_W));
    wire is_amoand_d  = (decoded_instruction == `INSTR_CODE(AMOAND_D));
    wire is_amomin_w  = (decoded_instruction == `INSTR_CODE(AMOMIN_W));
    wire is_amomin_d  = (decoded_instruction == `INSTR_CODE(AMOMIN_D));
    wire is_amomax_w  = (decoded_instruction == `INSTR_CODE(AMOMAX_W));
    wire is_amomax_d  = (decoded_instruction == `INSTR_CODE(AMOMAX_D));
    wire is_amominu_w = (decoded_instruction == `INSTR_CODE(AMOMINU_W));
    wire is_amominu_d = (decoded_instruction == `INSTR_CODE(AMOMINU_D));
    wire is_amomaxu_w = (decoded_instruction == `INSTR_CODE(AMOMAXU_W));
    wire is_amomaxu_d = (decoded_instruction == `INSTR_CODE(AMOMAXU_D));

    wire is_amoswap = is_amoswap_w || is_amoswap_d;

    wire is_amo_rmw_w = is_amoswap_w || is_amoadd_w || is_amoxor_w || is_amoor_w
                      || is_amoand_w || is_amomin_w || is_amomax_w || is_amominu_w || is_amomaxu_w;
    wire is_amo_rmw_d = is_amoswap_d || is_amoadd_d || is_amoxor_d || is_amoor_d
                      || is_amoand_d || is_amomin_d || is_amomax_d || is_amominu_d || is_amomaxu_d;
    assign is_amo_rmw = is_amo_rmw_w || is_amo_rmw_d;   // drives the forward-declared logic above

    /* All 22 -- used only by the address-phase operand-B redirect below. */
    wire is_amo_family = is_lr || is_sc || is_amo_rmw;

    /*
     * amo_modify_phase: true for exactly the cycles alu0's inputs must be
     * redirected from "compute the address" to "compute the modify
     * value" -- gated purely on state, not on is_amo_rmw, since
     * S_AMO_WRITE is a state ONLY an is_amo_rmw instruction can ever
     * reach (LR/SC never transition there), so the state check alone is
     * unambiguous.
     */
    wire amo_modify_phase = (state == S_AMO_WRITE);

    /*
     * LR/SC/AMO's address is rs1 alone, no offset -- imm_1 IS the
     * address, available immediately post-decode. Deliberately NOT
     * alu_result/mem_paddr here (even though they're numerically equal
     * during S_EXEC): sc_success below is needed by mem_control, which
     * is declared textually BEFORE alu0 exists (Execute comes later) --
     * using imm_1 sidesteps that ordering entirely rather than requiring
     * mem_control to be relocated after Execute.
     */
    wire [(`WORD_SIZE - 1):0] amo_target_addr = imm_1;

    /*
     * Reservation register (LR/SC). Set unconditionally on LR's own
     * retirement (a fresh LR always creates a new reservation,
     * superseding any prior one -- a plain overwrite, not a conditional
     * set). Cleared on ANY store-class instruction's retirement: ordinary
     * SB/SH/SW/SD (is_store), SC either way (is_sc, since is_store alone
     * only catches SC's MATCHED case), or an AMO's write (is_amo_rmw) --
     * matching the spec requirement that a used reservation can't be
     * reused.
     */
    logic reservation_valid_q;
    logic [(`WORD_SIZE - 1):0] reservation_addr_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            reservation_valid_q <= 1'b0;
        end else if (commit_now && is_lr) begin
            reservation_valid_q <= 1'b1;
            reservation_addr_q  <= amo_target_addr;
        end else if (commit_now && (is_store || is_sc || is_amo_rmw)) begin
            reservation_valid_q <= 1'b0;
        end
    end

    /*
     * sc_success: a pure register compare, no bus access needed -- known
     * combinationally as soon as decode settles in S_EXEC, and stable
     * for SC's entire (possibly multi-cycle) lifetime, since nothing
     * else can retire (and so mutate the reservation) while SC itself is
     * in flight.
     */
    wire sc_addr_match = reservation_valid_q && (reservation_addr_q == amo_target_addr);
    wire sc_success = is_sc && sc_addr_match;
    wire [(`WORD_SIZE - 1):0] sc_result = sc_success ? `WORD_SIZE'(0) : `WORD_SIZE'(1);

    /*
     * amo_rs2_operand: rs2, width-adjusted for the modify-phase
     * computation. Per spec, only rs2's low 32 bits are ever meaningful
     * for a .W op -- sign-extended here to 64 bits uniformly for ALL 9
     * RMW ops (not just the signed-compare ones), same pattern
     * is_div_w_family already uses for DIVW's divisor. Safe for every
     * op, not just the "obviously signed" ones: ADD/XOR/OR/AND's low-32-
     * bit result is provably invariant to how the upper 32 bits of
     * either 64-bit operand are populated, and MINU/MAXU's unsigned
     * 32-bit comparison is provably identical to an unsigned 64-bit
     * comparison of the two sign-extended operands (sign extension is an
     * order-preserving embedding for unsigned comparison too).
     */
    wire [(`WORD_SIZE - 1):0] amo_rs2_operand = is_amo_rmw_w ? {{32{imm_2[31]}}, imm_2[31:0]} : imm_2;

    /*
     * amo_modify_operand_a/b: AMOSWAP's "new value" is rs2 verbatim --
     * same "operand_b=0, ADD" passthrough trick LUI/CSRRW already use,
     * just with operand_a set to amo_rs2_operand instead of the default
     * imm_1. Every other RMW op reads the just-captured OLD value
     * (amo_rdata_q) as operand_a and rs2 as operand_b.
     */
    wire [(`WORD_SIZE - 1):0] amo_modify_operand_a = is_amoswap ? amo_rs2_operand : amo_rdata_q;
    wire [(`WORD_SIZE - 1):0] amo_modify_operand_b = is_amoswap ? `WORD_SIZE'(0)  : amo_rs2_operand;

    logic [(`ALU_OPSIZE - 1):0] amo_modify_op;
    always_comb begin: amo_modify_op_sel
        case (decoded_instruction)
            `INSTR_CODE(AMOSWAP_W), `INSTR_CODE(AMOSWAP_D): amo_modify_op = `ADD;  // passthrough
            `INSTR_CODE(AMOADD_W),  `INSTR_CODE(AMOADD_D):  amo_modify_op = `ADD;
            `INSTR_CODE(AMOXOR_W),  `INSTR_CODE(AMOXOR_D):  amo_modify_op = `XOR;
            `INSTR_CODE(AMOOR_W),   `INSTR_CODE(AMOOR_D):   amo_modify_op = `OR;
            `INSTR_CODE(AMOAND_W),  `INSTR_CODE(AMOAND_D):  amo_modify_op = `AND;
            `INSTR_CODE(AMOMIN_W),  `INSTR_CODE(AMOMIN_D):  amo_modify_op = `MIN;
            `INSTR_CODE(AMOMAX_W),  `INSTR_CODE(AMOMAX_D):  amo_modify_op = `MAX;
            `INSTR_CODE(AMOMINU_W), `INSTR_CODE(AMOMINU_D): amo_modify_op = `MINU;
            `INSTR_CODE(AMOMAXU_W), `INSTR_CODE(AMOMAXU_D): amo_modify_op = `MAXU;
            default: amo_modify_op = `ADD; // don't-care -- LR/SC never reach S_AMO_WRITE
        endcase
    end: amo_modify_op_sel

    logic [(`ALU_OPSIZE - 1):0] alu_op;
    always_comb begin: alu_op_sel
        /*
         * A extension: during S_AMO_WRITE, alu0 is being reused for the
         * modify computation (old value op rs2), not the address
         * computation every other state uses it for -- the first
         * state-dependent alu_op in this file. LR/SC/AMO-during-address-
         * phase need no arm inside the case below at all -- they fall
         * through the existing default: alu_op = `ADD, exactly like
         * branches/loads/stores/CSR do today.
         */
        if (amo_modify_phase) begin
            alu_op = amo_modify_op;
        end else
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
             * M extension: multiply. MULW reuses MUL (see is_word_arith
             * above). DIV/DIVU/REM/REMU (and their W variants) get no
             * arms here at all -- they don't use alu_result any more than
             * branches/JAL do (see the "M extension: divide" section
             * below), so they correctly fall through to the same
             * don't-care default as everything else that bypasses the
             * ALU.
             */
            `INSTR_CODE(MUL), `INSTR_CODE(MULW): alu_op = `MUL;
            `INSTR_CODE(MULH):                   alu_op = `MULH;
            `INSTR_CODE(MULHSU):                 alu_op = `MULHSU;
            `INSTR_CODE(MULHU):                  alu_op = `MULHU;

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

            /*
             * A extension. LR/AMO's read phase behaves exactly like
             * LW/LD (reusing load_data's existing byte/half/word/dword
             * formatting infrastructure with zero changes to it, per
             * spec's requirement that a .W AMO/LR sign-extend the loaded
             * word). SC's arm makes is_store a DYNAMIC, reservation-
             * dependent value: when sc_success=0, is_store=0 for that SC
             * => mem_phase_needed=0 => SC commits immediately in S_EXEC
             * via the unmodified existing commit_now formula, with
             * rd = sc_result = 1. No new logic needed for that path
             * specifically -- it falls out of the existing machinery
             * once is_store is correctly 0.
             */
            `INSTR_CODE(LR_W): begin is_load = 1'b1; mem_size = 2'b10; load_signed = 1'b1; end
            `INSTR_CODE(LR_D): begin is_load = 1'b1; mem_size = 2'b11; load_signed = 1'b1; end

            `INSTR_CODE(SC_W): begin is_store = sc_success; mem_size = 2'b10; end
            `INSTR_CODE(SC_D): begin is_store = sc_success; mem_size = 2'b11; end

            `INSTR_CODE(AMOSWAP_W), `INSTR_CODE(AMOADD_W), `INSTR_CODE(AMOXOR_W), `INSTR_CODE(AMOOR_W),
            `INSTR_CODE(AMOAND_W), `INSTR_CODE(AMOMIN_W), `INSTR_CODE(AMOMAX_W), `INSTR_CODE(AMOMINU_W),
            `INSTR_CODE(AMOMAXU_W):
                begin is_load = 1'b1; mem_size = 2'b10; load_signed = 1'b1; end

            `INSTR_CODE(AMOSWAP_D), `INSTR_CODE(AMOADD_D), `INSTR_CODE(AMOXOR_D), `INSTR_CODE(AMOOR_D),
            `INSTR_CODE(AMOAND_D), `INSTR_CODE(AMOMIN_D), `INSTR_CODE(AMOMAX_D), `INSTR_CODE(AMOMINU_D),
            `INSTR_CODE(AMOMAXU_D):
                begin is_load = 1'b1; mem_size = 2'b11; load_signed = 1'b1; end

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
            `INSTR_CODE(MRET), `INSTR_CODE(SRET), `INSTR_CODE(WFI), `INSTR_CODE(SFENCE_VMA),
            `INSTR_CODE(INVALID):
                reg_write_ctrl = 1'b0;
            default:
                reg_write_ctrl = 1'b1;
        endcase
    end: reg_write_control

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

    /*
     * Privilege / trap classification (U/S/M privilege-mode milestone).
     * Forward-declared, same reason csr_rdata is above: medeleg_w is
     * driven by csr_file0, not instantiated until Execute (needs
     * alu_result first), but trap_to_s below needs its value now, at
     * classification time.
     */
    logic [(`WORD_SIZE - 1):0] medeleg_w;

    wire is_mret = (decoded_instruction == `INSTR_CODE(MRET));
    wire is_sret = (decoded_instruction == `INSTR_CODE(SRET));

    /*
     * Illegal-instruction sources this milestone: a genuinely
     * unrecognized encoding, OR a CSR access below its address-encoded
     * minimum privilege (bits[9:8], computed from the ADDRESS,
     * independent of whether csr_file.sv actually backs it), OR MRET
     * below M-mode / SRET below S-mode (also illegal-instruction per
     * spec, not a separate source).
     *
     * Deliberately NOT covered: read-only-CSR-write attempts
     * (bits[11:10]) -- csr_file.sv already silently ignores these
     * (Zicsr milestone's own decision; core_zicsr_tb.sv's csrrwi-to-
     * mhartid case depends on that silent-ignore) -- and SFENCE.VMA
     * from U-mode (spec-should-trap, but decoded as an unconditional
     * NOP this milestone -- see its own comment in
     * instructions_and_masks.sv).
     */
    wire is_invalid_instr    = (decoded_instruction == `INSTR_CODE(INVALID));
    wire csr_priv_violation  = is_csr  && (imm_2[9:8] > 2'(current_priv));
    wire mret_priv_violation = is_mret && (current_priv != PRIV_M);
    wire sret_priv_violation = is_sret && (current_priv == PRIV_U);
    wire is_illegal_instr = is_invalid_instr || csr_priv_violation
                          || mret_priv_violation || sret_priv_violation;
    wire is_ecall = (decoded_instruction == `INSTR_CODE(ECALL));

    /* Exception codes, per spec's machine-cause table (synchronous only
     * -- bit 63/Interrupt is always 0, no interrupt source exists yet). */
    wire [3:0] exc_code = is_illegal_instr                     ? 4'd2  :
                           (is_ecall && current_priv == PRIV_U) ? 4'd8  :
                           (is_ecall && current_priv == PRIV_S) ? 4'd9  :
                           (is_ecall && current_priv == PRIV_M) ? 4'd11 :
                                                                   4'd0; // don't-care, gated by trap_taken

    wire trap_taken = commit_now && (is_illegal_instr || is_ecall);
    /* An M-mode trap never delegates, regardless of medeleg -- falls out
     * naturally here since current_priv==M forces this wire to 0. */
    wire trap_to_s  = trap_taken && (current_priv != PRIV_M) && medeleg_w[6'(exc_code)];
    wire [(`WORD_SIZE - 1):0] trap_cause = {60'b0, exc_code};
    wire [(`WORD_SIZE - 1):0] trap_val = is_illegal_instr
        ? {{(`WORD_SIZE - `INSTR_SIZE){1'b0}}, instruction} : `WORD_SIZE'(0);

    wire mret_taken = commit_now && is_mret && !mret_priv_violation;
    wire sret_taken = commit_now && is_sret && !sret_priv_violation;

    wire csr_we = is_csr && commit_now && !csr_write_suppress && !trap_taken;

    /*
     * reg_write: relocated here (from immediately after reg_write_control
     * above) since it now depends on trap_taken, which isn't computed
     * until this classification section -- reg_write itself is already
     * forward-declared near the top of the Decode section (`logic
     * reg_write;`), so driving it later in the file is a continuation of
     * that same established pattern, not a new one. A trapping
     * instruction never writes rd -- its "normal" semantics (including
     * whatever reg_write_ctrl computed) are entirely overridden by
     * trap-entry.
     */
    assign reg_write = reg_write_ctrl && commit_now && !trap_taken;

    /*
     * M extension: divide. DIV/DIVU/REM/REMU (and their W variants)
     * execute via design/divider.sv, a separate multi-cycle module, not
     * the (purely combinational) ALU -- mem_control/reg_write_control
     * above still need no new arms for these 8 codes, same reasoning as
     * the CSR classification above: mem_control's default (is_load=0,
     * is_store=0) and reg_write_control's default (reg_write_ctrl=1'b1)
     * both already do the right thing.
     *
     * The *W variants need their low-32-bit operands correctly sign- or
     * zero-extended to WORD_SIZE before reaching the divider (matching
     * DIVW/DIVUW/REMW/REMUW's spec-defined 32-bit-domain semantics) --
     * unlike MULW, this can't just reuse the 64-bit path and truncate
     * the RESULT afterward, since division (unlike multiplication mod
     * 2^n) genuinely depends on the operands' actual magnitude, not just
     * their low bits. The result side mirrors is_word_arith/
     * alu_result_w_trunc below: truncate+resign whichever of quotient/
     * remainder the instruction actually wants.
     */
    wire is_div    = (decoded_instruction == `INSTR_CODE(DIV));
    wire is_divu   = (decoded_instruction == `INSTR_CODE(DIVU));
    wire is_rem    = (decoded_instruction == `INSTR_CODE(REM));
    wire is_remu   = (decoded_instruction == `INSTR_CODE(REMU));
    wire is_divw   = (decoded_instruction == `INSTR_CODE(DIVW));
    wire is_divuw  = (decoded_instruction == `INSTR_CODE(DIVUW));
    wire is_remw   = (decoded_instruction == `INSTR_CODE(REMW));
    wire is_remuw  = (decoded_instruction == `INSTR_CODE(REMUW));
    wire is_div_family = is_div || is_divu || is_rem || is_remu
                       || is_divw || is_divuw || is_remw || is_remuw;
    wire is_div_w_family      = is_divw || is_divuw || is_remw || is_remuw;
    wire is_div_signed_family = is_div || is_rem || is_divw || is_remw;
    wire is_div_wants_quotient = is_div || is_divu || is_divw || is_divuw;

    wire [(`WORD_SIZE - 1):0] div_dividend_in =
        !is_div_w_family      ? imm_1 :
        is_div_signed_family  ? {{32{imm_1[31]}}, imm_1[31:0]} : {32'b0, imm_1[31:0]};
    wire [(`WORD_SIZE - 1):0] div_divisor_in =
        !is_div_w_family      ? imm_2 :
        is_div_signed_family  ? {{32{imm_2[31]}}, imm_2[31:0]} : {32'b0, imm_2[31:0]};

    /*
     * i_start deliberately does NOT need its own "have I already pulsed
     * this" flag -- divider_o_busy rises (registered, one cycle after
     * i_start) exactly in time to naturally gate this back to 0 on every
     * subsequent cycle of the same divide, so this is a clean one-cycle
     * pulse without extra bookkeeping here.
     *
     * (state == S_EXEC) is a REQUIRED third condition here, not
     * belt-and-suspenders -- decoded_instruction (and so is_div_family)
     * is only meaningful once a fetch has actually settled. During
     * S_FETCH's transient window, `instruction` still reads whatever the
     * PREVIOUS fetch's instr_line_q held, indexed by the NEW pc's own
     * pc[2] bit -- a stale, arbitrary combination that can alias to a
     * genuine div-family encoding purely by coincidence (found exactly
     * this way: DIVU's own encoding, still sitting in instr_line_q's low
     * half, aliased as "the next instruction" for one cycle while its
     * successor's real fetch was still in flight -- spuriously
     * retriggering the divider). commit_now and the S_EXEC transition
     * below don't need this same guard -- both are already nested inside
     * their own `state == S_EXEC` conditions -- but i_start drives
     * divider0 directly and unconditionally, so it has to check for
     * itself.
     */
    logic divider_o_busy, divider_o_done;
    logic [(`WORD_SIZE - 1):0] divider_o_quotient, divider_o_remainder;
    divider divider0 (
        .i_clk(clk), .i_rst(rst),
        .i_start(is_div_family && (state == S_EXEC) && !divider_o_busy && !divider_o_done),
        .i_dividend(div_dividend_in), .i_divisor(div_divisor_in), .i_signed(is_div_signed_family),
        .o_busy(divider_o_busy), .o_done(divider_o_done),
        .o_quotient(divider_o_quotient), .o_remainder(divider_o_remainder)
    );

    assign div_stall = is_div_family && !divider_o_done;
    wire [(`WORD_SIZE - 1):0] div_result_raw = is_div_wants_quotient ? divider_o_quotient : divider_o_remainder;
    wire [(`WORD_SIZE - 1):0] div_result = is_div_w_family
                                            ? {{32{div_result_raw[31]}}, div_result_raw[31:0]}
                                            : div_result_raw;

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
    /*
     * A extension: amo_modify_phase takes top priority -- during
     * S_AMO_WRITE, alu0 is computing the modify value (old op rs2), not
     * an address, and amo_modify_operand_a/b (declared above, in the A
     * extension classification section) already account for AMOSWAP's
     * passthrough shape. Outside that phase, LR/SC/AMO's address is rs1
     * alone (imm_1), so they fall through to the same default every
     * plain load/store already uses -- no address-phase arm needed here.
     */
    wire [(`WORD_SIZE - 1):0] alu_operand_a = amo_modify_phase          ? amo_modify_operand_a :
                                               (is_csr_rs || is_csr_rc)  ? csr_rdata :
                                               is_auipc                  ? pc        :
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
     *
     * is_amo_family's arm MUST sit above is_store here -- SC's is_store
     * is DYNAMICALLY 1 when matched (see mem_control above), and without
     * this arm operand_b would fall through to `is_store ? imm3_sext :
     * ...`, which is WRONG: imm3_sext reinterprets
     * o_imm_3_or_dest_addr as a signed S/B offset, but for an R-type-
     * shaped decode (which is what OUTPUT_R_TYPE_INSTR gives every
     * A-extension instruction) that port instead holds rd, zero-
     * extended -- a small positive "offset" that would silently corrupt
     * the address computation for any matched SC with a nonzero rd.
     * LR/AMO never set is_store at all, so they'd never have hit this
     * arm regardless, but SC's dynamic is_store makes the priority
     * ordering genuinely load-bearing, not just tidy.
     */
    wire [(`WORD_SIZE - 1):0] alu_operand_b = amo_modify_phase ? amo_modify_operand_b :
                                               is_amo_family     ? `WORD_SIZE'(0) :
                                               is_store            ? imm3_sext :
                                               is_auipc             ? imm_1 :
                                               is_csr_rs             ? imm_1 :
                                               is_csr_rc               ? ~imm_1 :
                                               is_csr_rw                 ? `WORD_SIZE'(0) :
                                                                            imm_2;

    logic [(`WORD_SIZE - 1):0] alu_result;
    alu alu0 (
        .i_operand_A(alu_operand_a),
        .i_operation(alu_op),
        .i_operand_B(alu_operand_b),
        .o_result(alu_result)
    );

    /*
     * A extension: amo_result_w_trunc is a SEPARATE wire from
     * alu_result_w_trunc (Writeback section, further down) rather than a
     * relocation of it -- deliberate, to avoid perturbing the
     * already-working M-extension writeback path in the same change.
     * Same formula, needed here (before Memory) rather than there (after
     * Wishbone-master bus-driving).
     *
     * Needed because a .W AMO's raw 64-bit alu0 output is NOT
     * automatically the correct sign-extension of the true 32-bit result
     * for every op -- ADD is the counter-example: sign-extend(0x7FFFFFFF)
     * + sign-extend(1) = 0x0000000080000000, but the CORRECT
     * sign-extension of the true 32-bit sum (0x7FFFFFFF+1=0x80000000,
     * i.e. INT32_MIN) is 0xFFFFFFFF80000000 -- different! (XOR/OR/AND and
     * MIN/MAX/MINU/MAXU happen to already be correctly sign-extended when
     * fed sign-extended operands, but applying this truncate+resign step
     * UNIFORMLY to all 9 ops is far simpler than reasoning per-op about
     * which ones need it.)
     */
    wire [(`WORD_SIZE - 1):0] amo_result_w_trunc = {{32{alu_result[31]}}, alu_result[31:0]};
    wire [(`WORD_SIZE - 1):0] amo_new_value = is_amo_rmw_w ? amo_result_w_trunc : alu_result;

    /*
     * csr_file0: instantiated here, after alu0 rather than up with the
     * rest of the new Zicsr wires in the Control unit section above --
     * its write data is alu_result, which by construction (see the
     * operand-mux/alu_op_sel comments above) is uniformly "the new CSR
     * value" for all 6 variants, and alu_result doesn't exist until
     * alu0 above is declared.
     */
    wire [(`WORD_SIZE - 1):0] mtvec_w, stvec_w, mepc_w, sepc_w;
    wire [1:0] mstatus_mpp_w;
    wire mstatus_spp_w;

    csr_file csr_file0 (
        .i_clk(clk),
        .i_rst(rst),
        .i_csr_addr(imm_2[(`CSR_ADDR_SIZE - 1):0]),
        .o_csr_rdata(csr_rdata),
        .i_csr_we(csr_we),
        .i_csr_wdata(alu_result),
        .i_instr_retired(commit_now),

        .i_current_priv(current_priv),
        .i_trap_taken(trap_taken),
        .i_trap_cause(trap_cause),
        .i_trap_val(trap_val),
        .i_trap_pc(pc),
        .i_trap_to_s(trap_to_s),
        .i_mret_taken(mret_taken),
        .i_sret_taken(sret_taken),

        .o_mtvec(mtvec_w),
        .o_stvec(stvec_w),
        .o_mepc(mepc_w),
        .o_sepc(sepc_w),
        .o_medeleg(medeleg_w),
        .o_mstatus_mpp(mstatus_mpp_w),
        .o_mstatus_spp(mstatus_spp_w)
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
    /*
     * mem_paddr: named indirection point for a future Sv39 MMU stage,
     * mirroring fetch_paddr above. All FOUR downstream consumers of
     * "alu_result as an address" route through this one wire, not just
     * mem_addr, so there's exactly one RHS to touch when Sv39 lands and
     * no risk of missing a spot. Deliberately WORD_SIZE-wide even though
     * only bits[31:0] are consumed today, same reasoning as fetch_paddr
     * above.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    wire [(`WORD_SIZE - 1):0] mem_paddr = alu_result;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [7:0] mem_sel = mem_size_mask << mem_paddr[2:0];

    /* Dword-aligned memory address -- same precompute-outside-always_comb reason as fetch_addr above. */
    wire [31:0] mem_addr = {mem_paddr[31:3], 3'b0};

    /* Store data, pre-shifted into the byte lane(s) it'll land in. */
    wire [(`WORD_SIZE - 1):0] mem_wdata = imm_2 << (mem_paddr[2:0] * 8);

    /* Read response, shifted back down so the wanted byte(s) start at bit 0. */
    wire [(`WORD_SIZE - 1):0] mem_rdata_shifted = wb_dat_i >> (mem_paddr[2:0] * 8);

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

    /*
     * A extension: amo_rdata_q/amo_addr_q/amo_sel_q, captured on the
     * S_MEM-ack-to-S_AMO_WRITE transition edge (the same edge
     * instr_line_q captures a fresh fetch on). amo_rdata_q holds the OLD
     * (pre-modification) memory value -- destined for rd. amo_addr_q/
     * amo_sel_q are NECESSARY, not just convenient: mem_addr/mem_sel are
     * combinational functions of mem_paddr(=alu_result), and alu_result
     * gets REPURPOSED for the modify value the instant amo_modify_phase
     * goes high (S_AMO_WRITE) -- so mem_addr/mem_sel, left un-latched,
     * would silently start reflecting the WRONG thing (the modify
     * computation, reinterpreted as an address) the moment S_AMO_WRITE
     * begins. Latching them at the one moment they're still correct
     * sidesteps that entirely.
     */
    always_ff @(posedge clk) begin
        if (state == S_MEM && wb_ack_i && is_amo_rmw) begin
            amo_rdata_q <= load_data;
            amo_addr_q  <= mem_addr;
            amo_sel_q   <= mem_sel;
        end
    end

    /* Shifted into byte-lane position, same idiom mem_wdata already uses. */
    wire [(`WORD_SIZE - 1):0] amo_wdata = amo_new_value << (amo_addr_q[2:0] * 8);

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
            /*
             * A extension: the write half of a read-modify-write AMO.
             * Reuses the exact same !wb_ack_i gating discipline as
             * S_FETCH/S_MEM above -- load-bearing here too, same reason.
             */
            S_AMO_WRITE: begin
                if (!wb_ack_i) begin
                    wb_cyc_o  = 1'b1;
                    wb_stb_o  = 1'b1;
                    wb_we_o   = 1'b1;      // always a write -- this state exists for exactly this
                    wb_addr_o = amo_addr_q;
                    wb_sel_o  = amo_sel_q;
                    wb_dat_o  = amo_wdata;
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
    /*
     * A extension: is_amo_rmw MUST be checked before is_load: is_load is
     * TRUE for an AMO's entire decode-level lifetime (see mem_control
     * above), but AMO only ever COMMITS during S_AMO_WRITE (never
     * S_MEM), at which point load_data/wb_dat_i reflect the WRITE
     * transaction's bus lines, not a real read -- using load_data here
     * would silently write garbage to rd. amo_rdata_q (the captured OLD
     * value, per spec -- NOT amo_new_value, which is the NEW value
     * destined for memory, not rd) is the correct, stable value at that
     * commit edge. is_sc's arm produces the success(0)/failure(1) flag
     * -- no existing arm could ever produce this.
     */
    assign reg_write_data = is_amo_rmw            ? amo_rdata_q :
                             is_sc                 ? sc_result :
                             is_load                ? load_data :
                             (is_jal || is_jalr)     ? pc_plus_4 :
                             is_word_arith            ? alu_result_w_trunc :
                             is_csr                    ? csr_rdata :
                             is_div_family               ? div_result :
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

    /*
     * Trap-vector redirect (U/S/M privilege-mode milestone). Direct mode
     * only -- mtvec/stvec's MODE bits[1:0] are stored as written (WARL)
     * but never consulted; Vectored mode's only benefit (cause-indexed
     * jump) is moot with no interrupt source, and even real
     * Vectored-mode hardware jumps straight to BASE for synchronous
     * exceptions regardless, per spec. trap_vector_base's own low 2
     * bits (the MODE field) are structurally never read below -- masked
     * off, not an oversight.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    wire [(`WORD_SIZE - 1):0] trap_vector_base = trap_to_s ? stvec_w : mtvec_w;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [(`WORD_SIZE - 1):0] trap_vector = {trap_vector_base[63:2], 2'b00};

    assign next_pc = trap_taken              ? trap_vector   :
                      mret_taken              ? mepc_w        :
                      sret_taken              ? sepc_w        :
                      (is_jal || take_branch) ? pc_rel_target :
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

    /*
     * current_priv (U/S/M privilege-mode milestone): resets to M per
     * spec. Updated by whichever of trap-entry/MRET/SRET fired this
     * edge -- at most one of the three can ever be true on the same
     * edge (see this file's Hazards reasoning in the project plan: a
     * trap always overrides an under-privileged MRET/SRET's own
     * mret_taken/sret_taken, via their !mret_priv_violation/
     * !sret_priv_violation gating).
     */
    always_ff @(posedge clk) begin
        if (rst)
            current_priv <= PRIV_M;
        else if (trap_taken)
            current_priv <= priv_t'(trap_to_s ? PRIV_S : PRIV_M);
        else if (mret_taken)
            current_priv <= priv_t'(mstatus_mpp_w);
        else if (sret_taken)
            current_priv <= priv_t'(mstatus_spp_w ? PRIV_S : PRIV_U);
    end

endmodule
