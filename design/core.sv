// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: core (single-cycle RV64I)
 *
 * Every instruction completes fetch through writeback within one clock
 * edge-to-edge cycle -- there is no FSM here at all. That's only possible
 * because imem/dmem (below) are purpose-built with combinational reads;
 * see their own header comments for why a Wishbone-attached memory like
 * design/wb4_sram.sv couldn't work here (its ack is a registered output,
 * a minimum 2-edge transaction by construction). Hooking this core up to
 * a real, registered memory system is a later milestone, not this one.
 *
 * decoder/alu/register_file are reused as-is (bugs fixed separately, see
 * their own files) rather than re-implemented here -- this module is
 * purely the glue between them: the PC, the control unit that decides
 * what each of them should do for a given decoded instruction, and the
 * muxes that route data between them.
 *
 * `INSTR_CODE(name)` (used throughout the control logic below) and every
 * ALU op name (`ADD, `SLTW, etc.) are inherited from decoder.sv's and
 * alu.sv's own `includes -- not re-included here, since both of those
 * modules are necessarily compiled/instantiated below already.
 *
 * Scope: full RV64I base ISA. No M/A/C extensions, no Zicsr/CSRs, no
 * privilege modes, no Sv39, no interrupts/exceptions -- all later
 * milestones. Misaligned access, FENCE, and ECALL are deliberately
 * under-implemented here (see their handling below) for the same reason.
 *
 * Input ports:
 *  clk: Clock.
 *  rst: Synchronous reset (active high) -- resets pc to 0 and clears
 *       `halted`. Does NOT reset register/memory contents; the ISA
 *       doesn't require it, and real hardware doesn't guarantee it
 *       either (only the reset vector is architecturally defined).
 */
module core (
    input logic clk,
    input logic rst
);

    /* --------------------------------------------------------------- *
     * Fetch
     * --------------------------------------------------------------- */

    logic [(`WORD_SIZE - 1):0] pc;
    logic [(`WORD_SIZE - 1):0] next_pc;

    logic [(`INSTR_SIZE - 1):0] instruction;

    imem imem0 (
        .i_addr(pc),
        .o_instruction(instruction)
    );

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
     * It settles in zero simulated time as a plain feedforward chain.
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

    wire is_auipc = (decoded_instruction == `INSTR_CODE(AUIPC));
    wire is_jal   = (decoded_instruction == `INSTR_CODE(JAL));
    wire is_jalr  = (decoded_instruction == `INSTR_CODE(JALR));

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

    logic is_load, is_store;
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
     * milestone adds more instructions.
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
    assign reg_write = reg_write_ctrl;

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
    wire [(`WORD_SIZE - 1):0] alu_operand_a = is_auipc ? pc : imm_1;
    wire [(`WORD_SIZE - 1):0] alu_operand_b = is_store  ? imm3_sext :
                                                is_auipc  ? imm_1     :
                                                             imm_2;

    logic [(`WORD_SIZE - 1):0] alu_result;
    alu alu0 (
        .i_operand_A(alu_operand_a),
        .i_operation(alu_op),
        .i_operand_B(alu_operand_b),
        .o_result(alu_result)
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
     * alu_result does double duty here: it's "the ALU's answer" for
     * every non-memory instruction, and "the memory address" for
     * loads/stores (base register + offset, computed by the same adder
     * via the operand muxing above) -- deliberate reuse of one datapath,
     * not a coincidence.
     */
    logic [(`WORD_SIZE - 1):0] dmem_rdata;
    dmem dmem0 (
        .i_clk(clk),
        .i_addr(alu_result),
        .i_size(mem_size),
        .i_write_enable(is_store),
        .i_write_data(imm_2),  // rs2 -- OUTPUT_S_TYPE_INSTR puts the store's source value here
        .o_read_data(dmem_rdata)
    );

    /* Shift dmem's line so the byte(s) we actually want start at bit 0. */
    wire [(`WORD_SIZE - 1):0] dmem_rdata_shifted = dmem_rdata >> (alu_result[2:0] * 8);

    /*
     * Precomputed slices, not inline inside load_format's case statement
     * below -- Icarus Verilog doesn't fully support constant selects
     * inside always_* processes (same reason as alu.sv's shamt_masked).
     */
    wire [7:0]  load_byte  = dmem_rdata_shifted[7:0];
    wire [15:0] load_half  = dmem_rdata_shifted[15:0];
    wire [31:0] load_word  = dmem_rdata_shifted[31:0];
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
            default: load_data = dmem_rdata_shifted; // 2'b11: doubleword, no extension needed
        endcase
    end: load_format

    /* --------------------------------------------------------------- *
     * Writeback
     * --------------------------------------------------------------- */

    wire [(`WORD_SIZE - 1):0] pc_plus_4 = pc + `WORD_SIZE'(4);

    /* See the is_word_arith comment above for why only some *W ops need this. */
    wire [(`WORD_SIZE - 1):0] alu_result_w_trunc = {{32{alu_result[31]}}, alu_result[31:0]};

    assign reg_write_data = is_load               ? load_data :
                             (is_jal || is_jalr)   ? pc_plus_4 :
                             is_word_arith         ? alu_result_w_trunc :
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
     * "extra" state in this design, beyond pc itself and the two
     * memories' write ports. Freezing pc (rather than letting it run on
     * into whatever follows EBREAK) is a deliberate choice: once
     * halted, the core would otherwise keep fetching and "executing"
     * subsequent memory contents, which is harmless if that's zeroed
     * (decodes as INVALID, a no-op) but isn't guaranteed to be zero in
     * every testbench. Testbenches watch this signal via a hierarchical
     * reference (e.g. dut.halted) to know when a test program has
     * finished running, without guessing a cycle count.
     */
    logic halted;
    always_ff @(posedge clk) begin
        if (rst)
            halted <= 1'b0;
        else if (decoded_instruction == `INSTR_CODE(EBREAK))
            halted <= 1'b1;
    end

    always_ff @(posedge clk) begin
        pc <= rst ? '0 : (halted ? pc : next_pc);
    end

endmodule
