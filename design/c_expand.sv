// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: c_expand (C extension: RVC decompressor)
 *
 * Pure combinational. Takes a 16-bit compressed (RVC) instruction and
 * expands it into the equivalent full 32-bit standard RISC-V encoding --
 * one design/decoder.sv ALREADY recognizes, byte-for-byte, via its
 * existing IS_INSTR masks. This is the entire reason decoder.sv needs
 * ZERO changes for the C extension: every RV64 Zca instruction (integer
 * compressed instructions only -- no Zcf/Zcd, since this core has no F/D)
 * is a compressed encoding of an operation the decoder already handles.
 *
 * design/core.sv is the only caller. It feeds this module the live
 * 16-bit halfword at the current fetch position and, when o_illegal is
 * asserted, substitutes a harmless `addi x0,x0,0` for o_instr32 rather
 * than trusting this module's (don't-care) output directly -- the real
 * illegal-instruction trap is wired through core.sv's own
 * is_illegal_instr, not through o_instr32's value. o_instr32 is
 * therefore genuinely don't-care whenever o_illegal=1.
 *
 * Register-field convention (the single easiest mistake in this file --
 * see the per-instruction comments below for which is which): CR-format
 * fields and every CI-format destination register are full, UNMAPPED
 * 5-bit indices (x0-x31). Only CIW/CL/CS/CA formats, and the
 * arithmetic/branch rows of CB, use the compressed 3-bit "popular
 * register" convention, mapped via creg() below to x8-x15.
 *
 * HINTs (rd=0/imm=0/shamt=0 on instructions where the spec designates
 * that combination a reserved-for-future-use hint rather than an error)
 * are expanded MECHANICALLY to their literal real instruction (e.g.
 * `addi x0,x0,0`) with no special-casing at all -- safe because writes
 * to x0 are already architecturally discarded downstream in core.sv,
 * matching this project's established "spec-legal no-op, decode but
 * treat as inert" philosophy already used for FENCE/WFI/SFENCE.VMA. Only
 * the genuinely RESERVED codepoints below assert o_illegal.
 *
 * Every immediate-scatter formula below was independently re-derived
 * against the ratified RVC spec bit tables during planning, not just
 * copied from a single source -- but this is the single highest-risk
 * area in the whole C-extension milestone (CI/CB/CJ formats are
 * genuinely bit-scrambled), and testbench/c_encode_crosscheck_tb.sv
 * (Pillar 3: a real riscv64-unknown-elf-as-assembled golden fixture) is
 * the actual arbiter of correctness -- treat every formula here as
 * provisional until that cross-check passes.
 */
module c_expand (
    input  logic [(`C_INSTR_SIZE - 1):0] i_instr16,
    output logic [(`INSTR_SIZE - 1):0]   o_instr32,
    output logic                          o_illegal
);

    /* "Popular register" convention: 3-bit compressed field -> x8-x15. */
    function automatic logic [4:0] creg(input logic [2:0] r);
        return {2'b01, r};
    endfunction

    /* R-type target, mirrors testbench/riscv_encode.sv's encode_r() exactly. */
    function automatic logic [31:0] mk_r(
        input logic [6:0] funct7, input logic [4:0] rs2, input logic [4:0] rs1,
        input logic [2:0] funct3, input logic [4:0] rd, input logic [6:0] opcode
    );
        return {funct7, rs2, rs1, funct3, rd, opcode};
    endfunction

    /* I-type target, mirrors encode_i(). imm12 already the final sign/zero-
     * extended-to-12-bits field -- callers do their own extension first. */
    function automatic logic [31:0] mk_i(
        input logic [11:0] imm12, input logic [4:0] rs1, input logic [2:0] funct3,
        input logic [4:0] rd, input logic [6:0] opcode
    );
        return {imm12, rs1, funct3, rd, opcode};
    endfunction

    /* S-type target, mirrors encode_s(). */
    function automatic logic [31:0] mk_s(
        input logic [11:0] imm12, input logic [4:0] rs2, input logic [4:0] rs1,
        input logic [2:0] funct3, input logic [6:0] opcode
    );
        return {imm12[11:5], rs2, rs1, funct3, imm12[4:0], opcode};
    endfunction

    /* B-type target, mirrors encode_b() -- imm13 is the actual signed byte
     * offset. Bit 0 is always 0 (branch targets are 2-byte-aligned) and
     * genuinely never read below -- not an oversight. */
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [31:0] mk_b(
        input logic [12:0] imm13, input logic [4:0] rs2, input logic [4:0] rs1,
        input logic [2:0] funct3, input logic [6:0] opcode
    );
        return {imm13[12], imm13[10:5], rs2, rs1, funct3, imm13[4:1], imm13[11], opcode};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    /* J-type target, mirrors encode_j() -- imm21 is the actual signed byte
     * offset, same "bit 0 always 0, genuinely unused" reasoning as mk_b. */
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [31:0] mk_j(
        input logic [20:0] imm21, input logic [4:0] rd, input logic [6:0] opcode
    );
        return {imm21[20], imm21[10:1], imm21[11], imm21[19:12], rd, opcode};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    /* RV64 shift-immediate target (6-bit shamt), mirrors encode_shift64(). */
    function automatic logic [31:0] mk_shift64(
        input logic [5:0] funct6, input logic [5:0] shamt, input logic [4:0] rs1,
        input logic [2:0] funct3, input logic [4:0] rd, input logic [6:0] opcode
    );
        return {funct6, shamt, rs1, funct3, rd, opcode};
    endfunction

    /* Opcodes/funct3 constants for the (already-decoder-recognized) 32-bit
     * targets this module expands into -- purely local readability, no
     * relation to design/defaults/instructions_and_masks.sv's own defines
     * (those are for MATCHING an already-fetched 32-bit word; this module
     * BUILDS one, so a plain local constant is simpler than pulling in and
     * re-deriving from that file's macro-heavy family shapes). */
    localparam logic [6:0] OPC_LOAD    = 7'b0000011;
    localparam logic [6:0] OPC_OP_IMM  = 7'b0010011;
    localparam logic [6:0] OPC_STORE   = 7'b0100011;
    localparam logic [6:0] OPC_OP      = 7'b0110011;
    localparam logic [6:0] OPC_LUI     = 7'b0110111;
    localparam logic [6:0] OPC_OP_IMM32= 7'b0011011;
    localparam logic [6:0] OPC_OP32    = 7'b0111011;
    localparam logic [6:0] OPC_JAL     = 7'b1101111;
    localparam logic [6:0] OPC_JALR    = 7'b1100111;
    localparam logic [6:0] OPC_BRANCH  = 7'b1100011;
    localparam logic [31:0] INSTR_EBREAK = 32'h00100073;

    /* Raw field extraction -- fixed bit positions, same idiom decoder.sv's
     * own source_1/source_2/destination assigns use. */
    wire [1:0] op      = i_instr16[1:0];
    wire [2:0] funct3  = i_instr16[15:13];
    wire [4:0] rd_rs1_full = i_instr16[11:7];   // CR/CI-format full register
    wire [4:0] rs2_full    = i_instr16[6:2];    // CR/CSS-format full register
    wire [2:0] rs1p_field  = i_instr16[9:7];    // CIW/CL/CS/CA/CB rs1'/rd' field
    wire [2:0] rs2p_field  = i_instr16[4:2];    // CL/CS/CA rd'/rs2' field
    wire [4:0] rd_p   = creg(rs2p_field);       // CIW/CL's rd'
    wire [4:0] rs1_p  = creg(rs1p_field);       // CL/CS/CA/CB's rs1'/rd'
    wire [4:0] rs2_p  = creg(rs2p_field);       // CS/CA's rs2'

    always_comb begin: c_expand_dispatch
        o_instr32 = 32'h00000013; // don't-care default (addi x0,x0,0)
        o_illegal = 1'b0;

        case (op)

        /* ---------------- Quadrant 0 (op=00) ---------------- */
        2'b00: begin
            case (funct3)
                3'b000: begin: c_addi4spn
                    /* nzuimm[9:6]=i[10:7] nzuimm[5:4]=i[12:11] nzuimm[3]=i[5]
                     * nzuimm[2]=i[6] -- NOT a plain high-to-low read; the
                     * low 2 bits are individually swapped vs. their natural
                     * position, a real, spec-mandated scramble. */
                    logic [9:0] nzuimm;
                    nzuimm = {i_instr16[10:7], i_instr16[12:11], i_instr16[5], i_instr16[6], 2'b00};
                    o_instr32 = mk_i({2'b00, nzuimm}, 5'd2, 3'b000, rd_p, OPC_OP_IMM);
                    /* Subsumes C.ILLEGAL (16'h0000): that pattern decodes as
                     * op=00,funct3=000,nzuimm=0 -- caught here, no separate
                     * all-zero comparator needed anywhere in this module. */
                    o_illegal = (nzuimm == 10'b0);
                end: c_addi4spn

                3'b010: begin: c_lw
                    /* C.LW's low 2 offset bits are SWAPPED relative to
                     * C.LD's below -- off[6]=i[5], off[2]=i[6] (not the
                     * "obvious" off[6:5]=i[6:5] shape C.LD uses). Real,
                     * independently spec-verified quirk -- do not
                     * "simplify" this to match C.LD's pattern. */
                    logic [6:0] off;
                    off = {i_instr16[5], i_instr16[12:10], i_instr16[6], 2'b00};
                    o_instr32 = mk_i({5'b00000, off}, rs1_p, 3'b010, rd_p, OPC_LOAD);
                end: c_lw

                3'b011: begin: c_ld
                    logic [7:0] off;
                    off = {i_instr16[6:5], i_instr16[12:10], 3'b000};
                    o_instr32 = mk_i({4'b0000, off}, rs1_p, 3'b011, rd_p, OPC_LOAD);
                end: c_ld

                3'b110: begin: c_sw
                    logic [6:0] off;
                    off = {i_instr16[5], i_instr16[12:10], i_instr16[6], 2'b00};
                    o_instr32 = mk_s({5'b00000, off}, rs2_p, rs1_p, 3'b010, OPC_STORE);
                end: c_sw

                3'b111: begin: c_sd
                    logic [7:0] off;
                    off = {i_instr16[6:5], i_instr16[12:10], 3'b000};
                    o_instr32 = mk_s({4'b0000, off}, rs2_p, rs1_p, 3'b011, OPC_STORE);
                end: c_sd

                /* funct3=001 (C.FLD/Zcd), 100 (spec-reserved, unassigned),
                 * 101 (C.FSD/Zcd) -- all illegal on this no-F/D core. */
                default: o_illegal = 1'b1;
            endcase
        end

        /* ---------------- Quadrant 1 (op=01) ---------------- */
        2'b01: begin
            case (funct3)
                3'b000: begin: c_addi
                    /* rd=0 and/or imm=0 (the latter is literally C.NOP) are
                     * both spec-legal HINTs -- expand mechanically, no
                     * special case needed (see module header). */
                    logic [11:0] imm;
                    imm = {{6{i_instr16[12]}}, i_instr16[12], i_instr16[6:2]};
                    o_instr32 = mk_i(imm, rd_rs1_full, 3'b000, rd_rs1_full, OPC_OP_IMM);
                end: c_addi

                3'b001: begin: c_addiw
                    /* Unlike C.ADDI, rd=0 here is RESERVED, not a HINT --
                     * the single easiest cross-instruction mistake in this
                     * module (do not copy c_addi's "always safe" reasoning
                     * here). RV64-only slot (RV32 uses this for C.JAL). */
                    logic [11:0] imm;
                    imm = {{6{i_instr16[12]}}, i_instr16[12], i_instr16[6:2]};
                    o_instr32 = mk_i(imm, rd_rs1_full, 3'b000, rd_rs1_full, OPC_OP_IMM32);
                    o_illegal = (rd_rs1_full == 5'd0);
                end: c_addiw

                3'b010: begin: c_li
                    logic [11:0] imm;
                    imm = {{6{i_instr16[12]}}, i_instr16[12], i_instr16[6:2]};
                    o_instr32 = mk_i(imm, 5'd0, 3'b000, rd_rs1_full, OPC_OP_IMM);
                    /* rd=0 -> HINT, expands harmlessly to addi x0,x0,imm. */
                end: c_li

                3'b011: begin: c_addi16sp_or_lui
                    if (rd_rs1_full == 5'd2) begin: c_addi16sp
                        /* nzimm[9]=i12 nzimm[8:7]=i[4:3] nzimm[6]=i5
                         * nzimm[5]=i2 nzimm[4]=i6 nzimm[3:0]=0 -- five
                         * independently-scattered single/double bit groups,
                         * the most scrambled CI-format immediate besides
                         * C.LWSP/C.LDSP. */
                        logic [9:0] nzimm10;
                        logic [11:0] imm12;
                        nzimm10 = {i_instr16[12], i_instr16[4:3], i_instr16[5],
                                   i_instr16[2], i_instr16[6], 4'b0000};
                        imm12 = {{2{i_instr16[12]}}, nzimm10};
                        o_instr32 = mk_i(imm12, 5'd2, 3'b000, 5'd2, OPC_OP_IMM);
                        o_illegal = (nzimm10 == 10'b0);
                    end: c_addi16sp
                    else begin: c_lui
                        /* nzimm[17]=i12 (sign bit), nzimm[16:12]=i[6:2] --
                         * sign-extended into the EXPANDED lui's 20-bit
                         * U-immediate field, which represents bits[31:12]
                         * of the eventual register value. rd=0 can't reach
                         * this branch (that's C.LI's op=01/funct3=010 slot,
                         * a completely different encoding) -- only the
                         * rd=x2 vs. rd-is-anything-else split lives here,
                         * so the only remaining HINT case is rd!=0,2 with
                         * imm=0, which IS separately reserved (not a HINT)
                         * per spec -- see o_illegal below.
                         */
                        logic [19:0] u_imm;
                        u_imm = {{14{i_instr16[12]}}, i_instr16[12], i_instr16[6:2]};
                        o_instr32 = {u_imm, rd_rs1_full, OPC_LUI};
                        o_illegal = (rd_rs1_full != 5'd0) && ({i_instr16[12], i_instr16[6:2]} == 6'b0);
                    end: c_lui
                end: c_addi16sp_or_lui

                3'b100: begin: c_arith_group
                    /* CB/CA shared funct3=100 territory: i[11:10] splits
                     * shift-imm/andi (CB) from reg-reg (CA). */
                    case (i_instr16[11:10])
                        2'b00: begin: c_srli
                            logic [5:0] shamt;
                            shamt = {i_instr16[12], i_instr16[6:2]};
                            o_instr32 = mk_shift64(6'b000000, shamt, rs1_p, 3'b101, rs1_p, OPC_OP_IMM);
                            /* shamt=0 -> HINT, harmless srli rd',rd',0. */
                        end: c_srli
                        2'b01: begin: c_srai
                            logic [5:0] shamt;
                            shamt = {i_instr16[12], i_instr16[6:2]};
                            o_instr32 = mk_shift64(6'b010000, shamt, rs1_p, 3'b101, rs1_p, OPC_OP_IMM);
                        end: c_srai
                        2'b10: begin: c_andi
                            logic [11:0] imm;
                            imm = {{6{i_instr16[12]}}, i_instr16[12], i_instr16[6:2]};
                            o_instr32 = mk_i(imm, rs1_p, 3'b111, rs1_p, OPC_OP_IMM);
                        end: c_andi
                        2'b11: begin: c_ca
                            /* Reg-reg among the 8 popular registers.
                             * i[12] splits 32-bit-result (0) from
                             * *W/RV64-word-result (1) ops; funct2=i[6:5]
                             * then selects the specific op within each. */
                            if (i_instr16[12] == 1'b0) begin
                                case (i_instr16[6:5])
                                    2'b00: o_instr32 = mk_r(7'b0100000, rs2_p, rs1_p, 3'b000, rs1_p, OPC_OP); // C.SUB
                                    2'b01: o_instr32 = mk_r(7'b0000000, rs2_p, rs1_p, 3'b100, rs1_p, OPC_OP); // C.XOR
                                    2'b10: o_instr32 = mk_r(7'b0000000, rs2_p, rs1_p, 3'b110, rs1_p, OPC_OP); // C.OR
                                    2'b11: o_instr32 = mk_r(7'b0000000, rs2_p, rs1_p, 3'b111, rs1_p, OPC_OP); // C.AND
                                endcase
                            end else begin
                                case (i_instr16[6:5])
                                    2'b00: o_instr32 = mk_r(7'b0100000, rs2_p, rs1_p, 3'b000, rs1_p, OPC_OP32); // C.SUBW
                                    2'b01: o_instr32 = mk_r(7'b0000000, rs2_p, rs1_p, 3'b000, rs1_p, OPC_OP32); // C.ADDW
                                    default: o_illegal = 1'b1; // funct2 10/11 reserved when i12=1
                                endcase
                            end
                        end: c_ca
                    endcase
                end: c_arith_group

                3'b101: begin: c_j
                    /* imm[11]=i12 imm[10]=i8 imm[9]=i10 imm[8]=i9 imm[7]=i6
                     * imm[6]=i7 imm[5]=i2 imm[4]=i11 imm[3]=i5 imm[2]=i4
                     * imm[1]=i3 imm[0]=0 -- the single most scrambled
                     * immediate in the whole ISA; every bit independently
                     * placed, no sub-field runs of >2 contiguous bits. */
                    logic [11:0] off12;
                    logic [20:0] imm21;
                    off12 = {i_instr16[12], i_instr16[8], i_instr16[10], i_instr16[9],
                             i_instr16[6], i_instr16[7], i_instr16[2], i_instr16[11],
                             i_instr16[5], i_instr16[4], i_instr16[3], 1'b0};
                    imm21 = {{9{off12[11]}}, off12};
                    o_instr32 = mk_j(imm21, 5'd0, OPC_JAL);
                end: c_j

                3'b110: begin: c_beqz
                    /* off[8]=i12 off[4:3]=i[11:10] off[7:6]=i[6:5]
                     * off[2:1]=i[4:3] off[5]=i2 -- one contiguous 2-bit
                     * run (off[4:3], off[7:6], off[2:1]) each, plus 2
                     * lone bits (off[8], off[5]). */
                    logic [8:0] off9;
                    logic [12:0] imm13;
                    off9 = {i_instr16[12], i_instr16[6], i_instr16[5], i_instr16[2],
                            i_instr16[11], i_instr16[10], i_instr16[4], i_instr16[3], 1'b0};
                    imm13 = {{4{off9[8]}}, off9};
                    o_instr32 = mk_b(imm13, 5'd0, rs1_p, 3'b000, OPC_BRANCH);
                end: c_beqz

                3'b111: begin: c_bnez
                    logic [8:0] off9;
                    logic [12:0] imm13;
                    off9 = {i_instr16[12], i_instr16[6], i_instr16[5], i_instr16[2],
                            i_instr16[11], i_instr16[10], i_instr16[4], i_instr16[3], 1'b0};
                    imm13 = {{4{off9[8]}}, off9};
                    o_instr32 = mk_b(imm13, 5'd0, rs1_p, 3'b001, OPC_BRANCH);
                end: c_bnez
            endcase
        end

        /* ---------------- Quadrant 2 (op=10) ---------------- */
        2'b10: begin
            case (funct3)
                3'b000: begin: c_slli
                    logic [5:0] shamt;
                    shamt = {i_instr16[12], i_instr16[6:2]};
                    o_instr32 = mk_shift64(6'b000000, shamt, rd_rs1_full, 3'b001, rd_rs1_full, OPC_OP_IMM);
                    /* rd=0 and/or shamt=0 -> HINT, harmless either way. */
                end: c_slli

                3'b010: begin: c_lwsp
                    /* off[7:6]=i[3:2] off[5]=i12 off[4:2]=i[6:4] -- NOT the
                     * same shape as C.LDSP below (that one's low field is a
                     * clean 3-bit run; this one splits 6:4/3:2 around the
                     * single sign/high bit at i12). */
                    logic [7:0] off;
                    off = {i_instr16[3:2], i_instr16[12], i_instr16[6:4], 2'b00};
                    o_instr32 = mk_i({4'b0000, off}, 5'd2, 3'b010, rd_rs1_full, OPC_LOAD);
                    o_illegal = (rd_rs1_full == 5'd0);
                end: c_lwsp

                3'b011: begin: c_ldsp
                    logic [8:0] off;
                    off = {i_instr16[4:2], i_instr16[12], i_instr16[6:5], 3'b000};
                    o_instr32 = mk_i({3'b000, off}, 5'd2, 3'b011, rd_rs1_full, OPC_LOAD);
                    o_illegal = (rd_rs1_full == 5'd0);
                end: c_ldsp

                3'b100: begin: c_cr_group
                    /* funct4 = {funct3(=100), i12}. rs2=rs2_full(i[6:2]). */
                    if (i_instr16[12] == 1'b0) begin
                        if (rs2_full == 5'd0) begin: c_jr
                            o_instr32 = mk_i(12'b0, rd_rs1_full, 3'b000, 5'd0, OPC_JALR);
                            o_illegal = (rd_rs1_full == 5'd0); // rs1=0 reserved
                        end: c_jr
                        else begin: c_mv
                            o_instr32 = mk_r(7'b0000000, rs2_full, 5'd0, 3'b000, rd_rs1_full, OPC_OP);
                            /* rd=0 -> HINT, harmless add x0,x0,rs2. */
                        end: c_mv
                    end else begin
                        if (rs2_full == 5'd0 && rd_rs1_full == 5'd0) begin: c_ebreak
                            o_instr32 = INSTR_EBREAK;
                        end: c_ebreak
                        else if (rs2_full == 5'd0) begin: c_jalr
                            o_instr32 = mk_i(12'b0, rd_rs1_full, 3'b000, 5'd1, OPC_JALR);
                        end: c_jalr
                        else begin: c_add
                            o_instr32 = mk_r(7'b0000000, rs2_full, rd_rs1_full, 3'b000, rd_rs1_full, OPC_OP);
                            /* rd=0 -> HINT, harmless add x0,x0,rs2. */
                        end: c_add
                    end
                end: c_cr_group

                3'b110: begin: c_swsp
                    logic [7:0] off;
                    off = {i_instr16[8:7], i_instr16[12:9], 2'b00};
                    o_instr32 = mk_s({4'b0000, off}, rs2_full, 5'd2, 3'b010, OPC_STORE);
                end: c_swsp

                3'b111: begin: c_sdsp
                    logic [8:0] off;
                    off = {i_instr16[9:7], i_instr16[12:10], 3'b000};
                    o_instr32 = mk_s({3'b000, off}, rs2_full, 5'd2, 3'b011, OPC_STORE);
                end: c_sdsp

                /* funct3=001 (C.FLDSP/Zcd), 101 (C.FSDSP/Zcd) -- illegal
                 * on this no-F/D core. */
                default: o_illegal = 1'b1;
            endcase
        end

        /* op=11: not a compressed instruction at all -- core.sv never
         * routes a real 32-bit-marked halfword through this module, so
         * this arm is structurally unreachable. Kept as a safe illegal
         * catch-all rather than an implicit latch/undriven case. */
        default: o_illegal = 1'b1;

        endcase
    end: c_expand_dispatch

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
