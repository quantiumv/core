// SPDX-License-Identifier: MIT

/*
 * qv_fp_dec -- classifies an F/D instruction from its bits (pure combinational).
 *
 * decoder.sv does not know the F/D encodings (its instruction-code space is nearly full and shared with the frozen
 * reference), so FP instructions keep its INVALID code and this module decides what they are. It takes the 32-bit
 * instruction after RVC expansion (C.FLD arrives as FLD) and after decode's fault substitution, plus mstatus.FS and
 * frm, and gives:
 *  - o_is_fp: the instruction is in an F/D opcode (LOAD-FP, STORE-FP, the four FMA opcodes, OP-FP);
 *  - o_illegal: it is not a legal F/D instruction here: FS is Off, the fmt is H or Q, a funct3/rs2 field is reserved,
 *    or the rounding mode is reserved (5 or 6, or rm = 7 with frm >= 5). Sail checks rm for every instruction that has
 *    an rm field, also where it cannot matter (FCVT.D.W, FCVT.D.S): verification/fpu/README.md, probes 40-55;
 *  - what it does: the FPU op, fmt, the integer type of a conversion, the resolved rounding mode; or, for FLW/FLD/
 *    FSW/FSD, a load or store of size 2 or 3 with its I- or S-immediate;
 *  - its operands: which of rs1, rs2, rs3 it reads and whether each is an FP register, and whether rd is an FP or an
 *    integer register.
 * fmt is the destination precision for FCVT.S.D / FCVT.D.S (the source is the other one).
 */
module qv_fp_dec (
    // rs1/rs2/rd numbers are read by decode itself; only the fields that classify are read here
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0]         i_instr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [1:0]          i_fs,          // mstatus.FS: 0 is Off
    input  logic [2:0]          i_frm,
    output logic                o_is_fp,
    output logic                o_illegal,
    output qv_pkg::qv_fp_op_e   o_op,
    output logic                o_fmt,
    output logic [1:0]          o_ityp,
    output logic [2:0]          o_rm,
    output logic                o_is_load,
    output logic                o_is_store,
    output logic [1:0]          o_mem_size,
    output logic [63:0]         o_imm,         // the load or store offset
    output logic                o_rs1_used,
    output logic                o_rs1_fp,
    output logic                o_rs2_used,
    output logic                o_rs2_fp,
    output logic                o_rs3_used,    // always an FP register
    output logic                o_rd_wen,
    output logic                o_rd_fp
);
    import qv_pkg::*;

    wire [6:0] opc    = i_instr[6:0];
    wire [2:0] f3     = i_instr[14:12];
    wire [4:0] rs2f   = i_instr[24:20];
    wire [4:0] f5     = i_instr[31:27];
    wire [1:0] fmtf   = i_instr[26:25];

    wire is_load_fp  = opc == 7'b0000111;
    wire is_store_fp = opc == 7'b0100111;
    wire is_fma      = opc == 7'b1000011 || opc == 7'b1000111 || opc == 7'b1001011 || opc == 7'b1001111;
    wire is_op_fp    = opc == 7'b1010011;

    // the rounding mode: a reserved static value, or dyn with a reserved frm, is illegal where rm is checked
    wire [2:0] rm_eff = (f3 == 3'b111) ? i_frm : f3;
    wire       rm_bad = (rm_eff == 3'b101) || (rm_eff == 3'b110) || (rm_eff == 3'b111);

    always_comb begin
        o_is_fp    = is_load_fp || is_store_fp || is_fma || is_op_fp;
        o_op       = QV_FP_ADD;
        o_fmt      = fmtf[0];
        o_ityp     = rs2f[1:0];
        o_rm       = rm_eff;
        o_is_load  = 1'b0;
        o_is_store = 1'b0;
        o_mem_size = 2'd3;
        o_imm      = '0;
        o_rs1_used = 1'b0;
        o_rs1_fp   = 1'b0;
        o_rs2_used = 1'b0;
        o_rs2_fp   = 1'b0;
        o_rs3_used = 1'b0;
        o_rd_wen   = 1'b0;
        o_rd_fp    = 1'b0;
        // reserved = an encoding with no instruction; checks_rm = it has an rm field
        begin : classify
            logic reserved, checks_rm;
            reserved  = 1'b0;
            checks_rm = 1'b0;
            if (is_load_fp || is_store_fp) begin
                reserved   = !(f3 == 3'b010 || f3 == 3'b011);       // FLW/FSW, FLD/FSD
                o_mem_size = f3[1:0];
                o_is_load  = is_load_fp;
                o_is_store = is_store_fp;
                o_imm      = is_load_fp ? {{52{i_instr[31]}}, i_instr[31:20]}
                                        : {{52{i_instr[31]}}, i_instr[31:25], i_instr[11:7]};
                o_rs1_used = 1'b1;                                   // the integer base address
                o_rs2_used = is_store_fp;
                o_rs2_fp   = is_store_fp;                            // the FP data
                o_rd_wen   = is_load_fp;
                o_rd_fp    = is_load_fp;
            end else if (is_fma) begin
                reserved   = fmtf[1];                                // H or Q
                checks_rm  = 1'b1;
                o_op       = qv_fp_op_e'((opc == 7'b1000011) ? QV_FP_MADD : (opc == 7'b1000111) ? QV_FP_MSUB :
                                         (opc == 7'b1001011) ? QV_FP_NMSUB : QV_FP_NMADD);
                o_rs1_used = 1'b1; o_rs1_fp = 1'b1;
                o_rs2_used = 1'b1; o_rs2_fp = 1'b1;
                o_rs3_used = 1'b1;
                o_rd_wen   = 1'b1; o_rd_fp  = 1'b1;
            end else if (is_op_fp) begin
                reserved   = fmtf[1];
                o_rs1_used = 1'b1; o_rs1_fp = 1'b1;
                o_rd_wen   = 1'b1; o_rd_fp  = 1'b1;
                case (f5)
                    5'b00000, 5'b00001, 5'b00010, 5'b00011: begin    // FADD FSUB FMUL FDIV
                        o_op = qv_fp_op_e'((f5 == 5'b00000) ? QV_FP_ADD : (f5 == 5'b00001) ? QV_FP_SUB :
                                           (f5 == 5'b00010) ? QV_FP_MUL : QV_FP_DIV);
                        checks_rm  = 1'b1;
                        o_rs2_used = 1'b1; o_rs2_fp = 1'b1;
                    end
                    5'b01011: begin                                  // FSQRT
                        o_op      = QV_FP_SQRT;
                        checks_rm = 1'b1;
                        reserved  = reserved || rs2f != 5'd0;
                    end
                    5'b00100: begin                                  // FSGNJ / FSGNJN / FSGNJX
                        o_op = qv_fp_op_e'((f3 == 3'b000) ? QV_FP_SGNJ : (f3 == 3'b001) ? QV_FP_SGNJN : QV_FP_SGNJX);
                        reserved   = reserved || f3 > 3'b010;
                        o_rs2_used = 1'b1; o_rs2_fp = 1'b1;
                    end
                    5'b00101: begin                                  // FMIN / FMAX
                        o_op = qv_fp_op_e'(f3[0] ? QV_FP_MAX : QV_FP_MIN);
                        reserved   = reserved || f3 > 3'b001;
                        o_rs2_used = 1'b1; o_rs2_fp = 1'b1;
                    end
                    5'b01000: begin                                  // FCVT.S.D (fmt S, rs2 1) / FCVT.D.S (fmt D, rs2 0)
                        o_op      = QV_FP_F2F;
                        checks_rm = 1'b1;
                        reserved  = reserved || rs2f != {4'b0, ~fmtf[0]};
                    end
                    5'b10100: begin                                  // FLE f3 0, FLT 1, FEQ 2
                        o_op = qv_fp_op_e'((f3 == 3'b010) ? QV_FP_EQ : (f3 == 3'b001) ? QV_FP_LT : QV_FP_LE);
                        reserved   = reserved || f3 > 3'b010;
                        o_rs2_used = 1'b1; o_rs2_fp = 1'b1;
                        o_rd_fp    = 1'b0;
                    end
                    5'b11000: begin                                  // FCVT.{W,WU,L,LU}.fmt
                        o_op      = QV_FP_F2I;
                        checks_rm = 1'b1;
                        reserved  = reserved || rs2f > 5'd3;
                        o_rd_fp   = 1'b0;
                    end
                    5'b11010: begin                                  // FCVT.fmt.{W,WU,L,LU}
                        o_op      = QV_FP_I2F;
                        checks_rm = 1'b1;
                        reserved  = reserved || rs2f > 5'd3;
                        o_rs1_fp  = 1'b0;
                    end
                    5'b11100: begin                                  // FMV.X.fmt f3 0, FCLASS f3 1
                        o_op      = qv_fp_op_e'(f3[0] ? QV_FP_CLASS : QV_FP_MV_XF);
                        reserved  = reserved || f3 > 3'b001 || rs2f != 5'd0;
                        o_rd_fp   = 1'b0;
                    end
                    5'b11110: begin                                  // FMV.fmt.X
                        o_op      = QV_FP_MV_FX;
                        reserved  = reserved || f3 != 3'b000 || rs2f != 5'd0;
                        o_rs1_fp  = 1'b0;
                    end
                    default: reserved = 1'b1;
                endcase
            end
            o_illegal = o_is_fp && (i_fs == 2'b00 || reserved || (checks_rm && rm_bad));
        end
    end
endmodule
