/*
 * lockstep_dbg.sv -- scripted debug-session stimulus (P6, pipelining
 * track plan). Instantiated once per side, next to that side's own
 * design/dm.sv, and drives the DM's plain register interface the way a
 * debugger would: halt, read and write registers through Access
 * Register commands, run Program Buffer snippets, set dcsr/triggers,
 * resume (sometimes single-stepping). It only watches its own side's
 * retirement stream and what it reads back, so two sides that retire
 * the same instruction sequence see the same script regardless of their
 * bus timing, exactly as lockstep_irq.sv promises for interrupts.
 *
 * Everything observable is logged to an event ring (kind, the side's own
 * retirement count, two payload words) that lockstep_cmp.sv compares in
 * order against the other side's: dpc/dcsr at every halt, every register
 * read, how every Program Buffer run ended, minstret. The retirement
 * count in each event is what catches a halt that lands one retirement
 * early or late inside a loop (dpc and the registers would match).
 *
 * Validity of the stimulus (what keeps the two sides comparable):
 *  - The halt request is the script's own level (OR'd with the DM's by
 *    lockstep_side.sv). It rises in the cycle after the retirement that
 *    reaches the target count, or one cycle later with late_i, exactly
 *    like lockstep_irq.sv's levels. Both cores sample it only in the
 *    cycle after a retirement, so both halt at the same boundary: after
 *    retirement K, or after K+1 with late_i. A longer delay would not
 *    be comparable (a core that can retire every cycle would be a
 *    retirement further along than one that retires every third).
 *  - Every random choice is drawn once per script operation, never per
 *    clock (a Program Buffer run takes different times on the two cores).
 *  - It never reads mip, mcycle or time, and changes only state the
 *    generated programs do not depend on: x22/x23 when feat_i[6] says
 *    the program leaves them alone (qvgen --dbg), any other register
 *    only with the value it just read from it, dcsr (step, ebreak and
 *    stopcount bits), dscratch0/1, tselect/tdata1/tdata2. It never
 *    touches mscratch/sscratch (the interrupt handlers keep their
 *    save-area pointers there) and never moves dpc: after an EBREAK
 *    entry it clears the ebreak bits and resumes at the same EBREAK
 *    (which now traps normally, whatever its length), after a trigger
 *    entry it disables the triggers.
 *  - Near a MAX_RETIRE stop (max_retire_i != 0) no new halt is
 *    requested and a spontaneous entry only reads dcsr/dpc and resumes,
 *    so no phase can be cut in half by the freeze of the side's clock
 *    (a run that stops at a program-flow store to tohost cannot be:
 *    nothing retires from the program while the hart is halted).
 *
 * feat_i bits: 0 halt, 1 step, 2 access (Access Register reads/writes),
 * 3 ebreak (arms dcsr.ebreak*), 4 trigger, 5 progbuf, 6 reserved
 * registers x22/x23 and the sandbox base x27 are the script's to use
 * (the program was generated with qvgen --dbg), 7 hold the halt request
 * across a resume, 8 action-0 triggers allowed. mode_i == 0 disables the
 * script.
 *
 * An action-0 trigger is a breakpoint exception, and the generated
 * programs' trap handlers answer a breakpoint by skipping the
 * instruction: skipping `auipc x25, 0` in the preamble, half of a
 * `lui`/`addi` pair or the `la` of a call site corrupts the program (and
 * usually makes it run forever). So the random corpus leaves bit 8 off
 * (triggers then only ever enter Debug Mode) and the directed
 * straight-line programs of dbg.list, where every instruction of the body
 * (from 0x40) is safe to skip, turn it on. Even then the script arms an
 * action-0 trigger only for a halt in [0x40, 0x8000): the set-up code and
 * the handler stay out of reach.
 */
`include "lockstep_defs.svh"
`ifndef QV_FPU_EN
`define QV_FPU_EN 0
`endif

module lockstep_dbg (
    input  logic        clk,
    input  logic        rst,

    input  logic [31:0] mode_i,
    input  logic [31:0] seed_i,
    input  logic [31:0] density_i,     // mean retirements between halts is about 8 * density_i
    input  logic [31:0] feat_i,
    input  logic        late_i,
    input  logic [63:0] max_retire_i,  // 0 = the run ends at a tohost store, not at a count

    input  logic        rvfi_valid,
    input  logic        debug_mode_i,  // core.o_debug_mode

    // the DM's plain register interface
    output logic [6:0]  o_reg_addr,
    output logic [31:0] o_reg_wdata,
    output logic        o_reg_we,
    input  logic [31:0] i_reg_rdata,

    // the script's own halt level
    output logic        o_halt_req,

    // event log
    output logic        o_ev_valid,
    output logic [3:0]  o_ev_kind,
    output logic [63:0] o_ev_order,
    output logic [63:0] o_ev_a,
    output logic [63:0] o_ev_b
);
    // F/D: with the FPU built in, the Access Register reads and read-back writes also pick FP registers (event payload
    // a = 32 + the register number) and Program Buffer snippet 15 reads them (choices and streams are unchanged
    // without it)
    localparam bit FPR = (`QV_FPU_EN != 0);

    localparam [3:0] EV_HALT = 4'd1, EV_MINSTRET = 4'd2, EV_GPR = 4'd3, EV_CSR = 4'd4, EV_WRITE = 4'd5,
                     EV_PB = 4'd6, EV_CMDERR = 4'd7, EV_RESUME = 4'd8;

    localparam [6:0] DMI_DATA0 = 7'h04, DMI_DATA1 = 7'h05, DMI_DMCONTROL = 7'h10,
                     DMI_ABSTRACTCS = 7'h16, DMI_COMMAND = 7'h17, DMI_PROGBUF0 = 7'h20;

    localparam [11:0] CSR_TSELECT = 12'h7A0, CSR_TDATA1 = 12'h7A1, CSR_TDATA2 = 12'h7A2,
                      CSR_DCSR = 12'h7B0, CSR_DPC = 12'h7B1, CSR_DSCRATCH0 = 12'h7B2,
                      CSR_DSCRATCH1 = 12'h7B3, CSR_MINSTRET = 12'hB02;

    // a phase retires at most 6 operations x 16 Program Buffer words, plus single steps
    localparam int PHASE_MARGIN = 160;

    // what the script may read: nothing timing-dependent
    localparam int N_CSR_READS = 24;
    function automatic [11:0] csr_read_addr(input integer i);
        case (i)
            0:  csr_read_addr = 12'h7B0;   // dcsr
            1:  csr_read_addr = 12'h7B1;   // dpc
            2:  csr_read_addr = 12'hB02;   // minstret
            3:  csr_read_addr = 12'h300;   // mstatus
            4:  csr_read_addr = 12'h304;   // mie
            5:  csr_read_addr = 12'h305;   // mtvec
            6:  csr_read_addr = 12'h340;   // mscratch
            7:  csr_read_addr = 12'h341;   // mepc
            8:  csr_read_addr = 12'h342;   // mcause
            9:  csr_read_addr = 12'h343;   // mtval
            10: csr_read_addr = 12'h7B2;   // dscratch0
            11: csr_read_addr = 12'h7B3;   // dscratch1
            12: csr_read_addr = 12'h7A0;   // tselect
            13: csr_read_addr = 12'h7A1;   // tdata1
            14: csr_read_addr = 12'h7A2;   // tdata2
            15: csr_read_addr = 12'h301;   // misa
            16: csr_read_addr = 12'h100;   // sstatus
            17: csr_read_addr = 12'h105;   // stvec
            18: csr_read_addr = 12'h141;   // sepc
            19: csr_read_addr = 12'h142;   // scause
            20: csr_read_addr = 12'h143;   // stval
            21: csr_read_addr = 12'h302;   // medeleg
            22: csr_read_addr = 12'h303;   // mideleg
            default: csr_read_addr = 12'h3A0;  // pmpcfg0
        endcase
    endfunction

    // ------------------------------------------------------------------
    // retirement count and the random stream
    // ------------------------------------------------------------------
    logic [63:0] retired_q;
    always @(posedge clk) begin
        if (rst)             retired_q <= 64'b0;
        else if (rvfi_valid) retired_q <= retired_q + 64'b1;
    end

    // xorshift32. Called as a statement-level step, never inside an
    // expression that also reads rng (operand evaluation order is not
    // defined), and never per clock.
    logic [31:0] rng;
    function automatic logic [31:0] next32(input integer unused);
        logic [31:0] x;
        begin
            x = rng;
            x = x ^ (x << 13);
            x = x ^ (x >> 17);
            x = x ^ (x << 5);
            rng = x;
            next32 = x;
        end
    endfunction

    function automatic integer rnd(input integer n);
        logic [31:0] x;
        begin
            x = next32(0);
            rnd = (n <= 1) ? 0 : integer'(x % 32'(n));
        end
    endfunction

    // ------------------------------------------------------------------
    // port-level tasks (everything is driven one time unit after a clock
    // edge, so the core and the DM see it at the next edge)
    // ------------------------------------------------------------------
    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic fail(input string msg);
        begin
            $display("LOCKSTEP_RESULT: FAIL (debug script: %s)", msg);
            $finish;
        end
    endtask

    logic trace_on;
    initial trace_on = $test$plusargs("DBG_TRACE");

    task automatic ev(input [3:0] kind, input [63:0] a, input [63:0] b);
        begin
            if (trace_on) $display("DBGTRACE %m t=%0t order=%0d kind=%0d a=%016h b=%016h", $time, retired_q, kind, a, b);
            o_ev_kind  = kind;
            o_ev_order = retired_q;
            o_ev_a     = a;
            o_ev_b     = b;
            o_ev_valid = 1'b1;
            tick;
            o_ev_valid = 1'b0;
        end
    endtask

    task automatic dmi_write(input [6:0] a, input [31:0] d);
        begin
            o_reg_addr  = a;
            o_reg_wdata = d;
            o_reg_we    = 1'b1;
            tick;
            o_reg_we    = 1'b0;
        end
    endtask

    task automatic dmi_read(input [6:0] a, output [31:0] d);
        begin
            o_reg_addr = a;
            tick;
            d = i_reg_rdata;
        end
    endtask

    // Access Register command: {cmdtype 8, rsvd 1, aarsize 3 (64-bit), postinc 1, postexec, transfer, write, regno 16}
    function automatic [31:0] ar_cmd(input logic wr, input [15:0] regno);
        ar_cmd = {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, wr, regno};
    endfunction
    localparam [31:0] PB_CMD = {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 1'b0, 16'h0000};

    task automatic wait_not_busy(output [2:0] cmderr);
        logic [31:0] cs;
        integer n;
        begin
            n = 0;
            cs = 32'h0000_1000;
            while (cs[12]) begin
                if (n >= 20000) fail("abstractcs.busy never cleared");
                dmi_read(DMI_ABSTRACTCS, cs);
                n = n + 1;
            end
            cmderr = cs[10:8];
        end
    endtask

    task automatic clear_cmderr;
        begin
            dmi_write(DMI_ABSTRACTCS, 32'h0000_0700);
        end
    endtask

    task automatic ar_read(input [15:0] regno, output [63:0] val);
        logic [31:0] d0, d1;
        logic [2:0]  ce;
        begin
            dmi_write(DMI_COMMAND, ar_cmd(1'b0, regno));
            wait_not_busy(ce);
            dmi_read(DMI_DATA0, d0);
            dmi_read(DMI_DATA1, d1);
            val = {d1, d0};
            if (ce != 3'd0) begin
                ev(EV_CMDERR, {48'b0, regno}, {61'b0, ce});
                clear_cmderr;
            end
        end
    endtask

    task automatic ar_write(input [15:0] regno, input [63:0] val);
        logic [2:0] ce;
        begin
            dmi_write(DMI_DATA0, val[31:0]);
            dmi_write(DMI_DATA1, val[63:32]);
            dmi_write(DMI_COMMAND, ar_cmd(1'b1, regno));
            wait_not_busy(ce);
            if (ce != 3'd0) begin
                ev(EV_CMDERR, {48'b0, regno}, {61'b0, ce});
                clear_cmderr;
            end
        end
    endtask

    // 0-31: x0-x31; 32-63: f0-f31 (regno 0x1020-0x103F, only with FPR)
    function automatic [15:0] gpr_regno(input integer k);
        gpr_regno = 16'h1000 + 16'(k);
    endfunction

    // ------------------------------------------------------------------
    // Program Buffer snippets
    // ------------------------------------------------------------------
    logic [31:0] pbw [0:15];
    integer      pbn;
    localparam [31:0] EBREAK = 32'h0010_0073;

    function automatic [31:0] enc_i(input [11:0] imm, input [4:0] rs1, input [2:0] f3, input [4:0] rd, input [6:0] op);
        enc_i = {imm, rs1, f3, rd, op};
    endfunction
    function automatic [31:0] enc_r(input [6:0] f7, input [4:0] rs2, input [4:0] rs1, input [2:0] f3, input [4:0] rd, input [6:0] op);
        enc_r = {f7, rs2, rs1, f3, rd, op};
    endfunction
    function automatic [31:0] enc_s(input [11:0] imm, input [4:0] rs2, input [4:0] rs1, input [2:0] f3);
        enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], 7'b0100011};
    endfunction
    function automatic [31:0] enc_jal(input [4:0] rd, input [20:0] off);
        enc_jal = {off[20], off[10:1], off[11], off[19:12], rd, 7'b1101111};
    endfunction
    function automatic [31:0] enc_beq(input [4:0] rs1, input [4:0] rs2, input [12:0] off);
        enc_beq = {off[12], off[10:5], rs2, rs1, 3'b000, off[4:1], off[11], 7'b1100011};
    endfunction
    function automatic [31:0] enc_csr(input [11:0] csr, input [4:0] rs1, input [2:0] f3, input [4:0] rd);
        enc_csr = {csr, rs1, f3, rd, 7'b1110011};
    endfunction
    function automatic [31:0] enc_amo(input [4:0] f5, input [4:0] rs2, input [4:0] rs1, input [2:0] f3, input [4:0] rd);
        enc_amo = {f5, 1'b0, 1'b0, rs2, rs1, f3, rd, 7'b0101111};
    endfunction

    // What a snippet must not do, because the FSM and the pipe both do the right thing but report it differently:
    //  - abort on a faulting load or AMO read, or on a misaligned load, LR, SC or AMO: rvfi_trap is 0 for a Program
    //    Buffer abort, so the comparator checks mem_* and rdata/wdata, and the FSM reports the stale bus and AMO
    //    registers (a misaligned SC without a reservation: wmask 0) where the pipe reports the would-be access
    //    (rdata 0). dm_tb Test E covers those. Snippet 10, a misaligned plain store, is the one abort whose fields agree.
    //  - store into the code: no FENCE.I follows, so what each core fetches next is unspecified.
    //  - change a word of the Program Buffer while a run is in flight (the pipe latches the word at injection, the FSM
    //    reads it until the commit); the script only touches it between runs, as a debugger that polls busy does.

    // Fill pbw[0..pbn-1] with one snippet. ra/rb are x22/x23 when the
    // program leaves them alone, x0 otherwise (so the words are still
    // there to be executed and retired, with no architectural effect).
    // The sandbox snippets (3, 9, 10, 14) need the qvgen sandbox base in x27, so
    // they only exist for reserved programs.
    task automatic make_snippet(input integer which_in, input logic reserved);
        logic [4:0] ra, rb;
        integer which, i, k;
        begin
            ra    = reserved ? 5'd22 : 5'd0;
            rb    = reserved ? 5'd23 : 5'd0;
            which = ((which_in == 3 || which_in == 9 || which_in == 10 || which_in == 14) && !reserved) ? 0 : which_in;
            pbn   = 0;
            case (which)
                0: begin   // ALU chain
                    k = 1 + rnd(2000);
                    pbw[0] = enc_i(12'(k), ra, 3'b000, ra, 7'b0010011);                   // addi
                    pbw[1] = enc_r(7'b0000000, ra, rb, 3'b100, rb, 7'b0110011);           // xor
                    k = 1 + rnd(30);
                    pbw[2] = enc_i(12'(k), ra, 3'b001, ra, 7'b0010011);                   // slli
                    pbw[3] = enc_r(7'b0000000, ra, rb, 3'b000, rb, 7'b0110011);           // add
                    pbw[4] = EBREAK; pbn = 5;
                end
                1: begin   // CSR traffic on the debug scratch registers and dpc
                    k = 1 + rnd(30);
                    pbw[0] = enc_csr(CSR_DSCRATCH0, rb, 3'b001, ra);                      // csrrw ra, dscratch0, rb
                    pbw[1] = enc_csr(CSR_DSCRATCH1, 5'd0, 3'b010, rb);                    // csrrs rb, dscratch1, x0
                    pbw[2] = enc_csr(CSR_DSCRATCH1, 5'(k), 3'b101, 5'd0);                 // csrrwi x0, dscratch1, uimm
                    pbw[3] = enc_csr(CSR_DPC, 5'd0, 3'b010, ra);                          // csrrs ra, dpc, x0
                    pbw[4] = EBREAK; pbn = 5;
                end
                2: begin   // branches and jumps: the slot index ignores them, the drifting pc does not
                    pbw[0] = enc_jal(ra, 21'd8);
                    pbw[1] = enc_i(12'd1, rb, 3'b000, rb, 7'b0010011);
                    pbw[2] = enc_beq(5'd0, 5'd0, 13'd8);
                    pbw[3] = enc_i(12'd2, rb, 3'b000, rb, 7'b0010011);
                    pbw[4] = {20'b0, ra, 7'b0010111};                                     // auipc ra, 0
                    pbw[5] = EBREAK; pbn = 6;
                end
                3: begin   // memory through the sandbox base (qvgen programs only), anywhere in its first KiB:
                           // that is where --pmp puts its pockets, which a Program Buffer access ignores
                    k = 8 * rnd(128);
                    i = 4 * rnd(256);
                    pbw[0] = enc_s(12'(k), rb, 5'd27, 3'b011);                            // sd rb, k(x27)
                    pbw[1] = enc_i(12'(k), 5'd27, 3'b011, ra, 7'b0000011);                // ld ra, k(x27)
                    pbw[2] = enc_s(12'(i), rb, 5'd27, 3'b010);                            // sw rb, i(x27)
                    pbw[3] = enc_i(12'(i), 5'd27, 3'b010, ra, 7'b0000011);                // lw ra, i(x27)
                    k = rnd(1024);
                    pbw[4] = enc_i(12'(k), 5'd27, 3'b100, rb, 7'b0000011);                // lbu rb, k(x27)
                    pbw[5] = EBREAK; pbn = 6;
                end
                4: begin   // system words: FENCE.I must drain fetch and flush the icache
                    pbw[0] = 32'h0000_100F;                                               // fence.i
                    pbw[1] = 32'h1050_0073;                                               // wfi
                    pbw[2] = 32'h0FF0_000F;                                               // fence
                    pbw[3] = enc_i(12'd1, ra, 3'b000, ra, 7'b0010011);
                    pbw[4] = EBREAK; pbn = 5;
                end
                5: begin   // abort: ECALL
                    pbw[0] = enc_i(12'd1, ra, 3'b000, ra, 7'b0010011);
                    pbw[1] = 32'h0000_0073;                                               // ecall
                    pbw[2] = EBREAK; pbn = 3;
                end
                6: begin   // abort: illegal word
                    pbw[0] = enc_i(12'd1, ra, 3'b000, ra, 7'b0010011);
                    pbw[1] = 32'h0000_0000;
                    pbw[2] = EBREAK; pbn = 3;
                end
                7: begin   // xRET: no effect in the Program Buffer (illegal below M for MRET)
                    k = rnd(2);
                    pbw[0] = (k == 0) ? 32'h3020_0073 : 32'h1020_0073;                    // mret / sret
                    pbw[1] = enc_i(12'd1, ra, 3'b000, ra, 7'b0010011);
                    pbw[2] = EBREAK; pbn = 3;
                end
                8: begin   // a full 16-word buffer
                    for (i = 0; i < 15; i = i + 1)
                        pbw[i] = enc_i(12'd1, ra, 3'b000, ra, 7'b0010011);
                    pbw[15] = EBREAK; pbn = 16;
                end
                9: begin   // atomics through the sandbox base: LR, SC, AMOADD (the lock, the reservation)
                    pbw[0] = enc_amo(5'b00010, 5'd0, 5'd27, 3'b011, ra);                  // lr.d ra, (x27)
                    pbw[1] = enc_amo(5'b00011, rb, 5'd27, 3'b011, rb);                    // sc.d rb, rb, (x27)
                    pbw[2] = enc_amo(5'b00000, rb, 5'd27, 3'b011, ra);                    // amoadd.d ra, rb, (x27)
                    pbw[3] = EBREAK; pbn = 4;
                end
                10: begin  // abort: a misaligned store (cause 6)
                    pbw[0] = enc_i(12'd1, ra, 3'b000, ra, 7'b0010011);
                    pbw[1] = enc_s(12'd1, rb, 5'd27, 3'b010);                             // sw rb, 1(x27)
                    pbw[2] = EBREAK; pbn = 3;
                end
                11: begin  // multiply and divide, including a divide by the other register
                    pbw[0] = enc_r(7'b0000001, rb, ra, 3'b000, ra, 7'b0110011);           // mul ra, ra, rb
                    pbw[1] = enc_r(7'b0000001, rb, ra, 3'b101, rb, 7'b0110011);           // divu rb, ra, rb
                    pbw[2] = enc_r(7'b0000001, ra, rb, 3'b111, ra, 7'b0110011);           // remu ra, rb, ra
                    pbw[3] = enc_r(7'b0000001, ra, rb, 3'b100, rb, 7'b0111011);           // divw rb, rb, ra
                    pbw[4] = EBREAK; pbn = 5;
                end
                12: begin  // reads of counters and status: minstret (stopcount!), mstatus, mcause, mtvec
                    pbw[0] = enc_csr(CSR_MINSTRET, 5'd0, 3'b010, ra);                     // csrrs ra, minstret, x0
                    pbw[1] = enc_csr(12'h300, 5'd0, 3'b010, rb);                          // csrrs rb, mstatus, x0
                    pbw[2] = enc_csr(12'h342, 5'd0, 3'b010, ra);                          // csrrs ra, mcause, x0
                    pbw[3] = enc_csr(12'h305, 5'd0, 3'b010, rb);                          // csrrs rb, mtvec, x0
                    pbw[4] = EBREAK; pbn = 5;
                end
                13: begin  // abort: a write to a read-only CSR, with a destination (neither it nor rd may change)
                    pbw[0] = enc_csr(12'hF14, rb, 3'b001, ra);                            // csrrw ra, mhartid, rb
                    pbw[1] = EBREAK; pbn = 2;
                end
                15: begin  // F/D: FP registers and fcsr read into the script's registers; feq raises NV on an sNaN
                           // (fflags and FS change the same way in both cores); with FS Off an illegal-instruction abort
                    k = rnd(32);
                    i = rnd(32);
                    pbw[0] = enc_r(7'b1110001, 5'd0, 5'(k), 3'b000, ra, 7'b1010011);      // fmv.x.d ra, fk
                    pbw[1] = enc_r(7'b1110001, 5'd0, 5'(i), 3'b001, rb, 7'b1010011);      // fclass.d rb, fi
                    pbw[2] = enc_r(7'b1010001, 5'(i), 5'(k), 3'b010, ra, 7'b1010011);     // feq.d ra, fk, fi
                    pbw[3] = enc_csr(12'h003, 5'd0, 3'b010, rb);                          // frcsr rb
                    pbw[4] = EBREAK; pbn = 5;
                end
                14: begin  // memory through x27 + 0x1000, qvgen --sv39's remapped page (VA 0x11000 -> PA 0x31000): a
                           // Program Buffer access is not translated, so it must land at PA 0x11000 + k. The data
                           // read back is the same either way; what tells them apart is the address (RVFI mem_addr,
                           // the bus-write log)
                    k = 8 * rnd(100);
                    pbw[0] = {20'd1, ra, 7'b0110111};                                     // lui ra, 1
                    pbw[1] = enc_r(7'b0000000, 5'd27, ra, 3'b000, ra, 7'b0110011);        // add ra, ra, x27
                    pbw[2] = enc_s(12'(k), rb, ra, 3'b011);                               // sd rb, k(ra)
                    pbw[3] = enc_i(12'(k), ra, 3'b011, rb, 7'b0000011);                   // ld rb, k(ra)
                    pbw[4] = EBREAK; pbn = 5;
                end
                default: begin
                    pbw[0] = EBREAK; pbn = 1;
                end
            endcase
        end
    endtask

    task automatic pb_run(input integer which_in, input logic reserved);
        logic [2:0]  ce;
        logic [63:0] x27v;
        integer      i, which;
        begin
            which = which_in;
            // The sandbox snippets (3, 9, 10, 14) go through x27, which the program's preamble sets to the sandbox base.
            // A halt before that finds x27 = 0, and a store through it lands in the code ahead of the pc: no FENCE.I
            // follows, so the two cores may fetch different bytes, and the program is wrecked anyway. (Under --sv39 a
            // seed with a data window has x27 elsewhere: no sandbox snippets then either.)
            if (reserved && (which == 3 || which == 9 || which == 10 || which == 14)) begin
                ar_read(gpr_regno(27), x27v);
                if (x27v != 64'h10000) which = 0;
            end
            make_snippet(which, reserved);
            for (i = 0; i < pbn; i = i + 1)
                dmi_write(DMI_PROGBUF0 + 7'(i), pbw[i]);
            dmi_write(DMI_COMMAND, PB_CMD);
            wait_not_busy(ce);
            ev(EV_PB, {61'b0, ce}, {60'b0, 4'(which)});
            if (ce != 3'd0) clear_cmderr;
        end
    endtask

    // ------------------------------------------------------------------
    // one halted phase and the resume
    // ------------------------------------------------------------------
    logic        hold_across_q;      // the halt level stays up through the next resume
    integer      steps_left;
    logic        last_phase;

    task automatic halted_phase;
        logic [63:0] dcsr, dpc, v, newdcsr, back;
        logic [31:0] lo, hi;
        logic [2:0]  cause;
        logic        reserved, wind_down;
        integer      nops, k, choice, r, slot, cnt, b15, b13, b12;
        begin
            reserved  = feat_i[6];
            wind_down = last_phase || (max_retire_i != 64'b0 && (retired_q + 64'(PHASE_MARGIN) > max_retire_i));
            ar_read({4'b0, CSR_DCSR}, dcsr);
            ar_read({4'b0, CSR_DPC},  dpc);
            ev(EV_HALT, dpc, dcsr);
            ar_read({4'b0, CSR_MINSTRET}, v);
            ev(EV_MINSTRET, v, 64'b0);
            cause = dcsr[8:6];

            nops = wind_down ? 0 : 1 + rnd(6);
            if (!wind_down && steps_left > 0) nops = 1;
            for (k = 0; k < nops; k = k + 1) begin
                choice = rnd(8);
                case (choice)
                    0, 1: if (feat_i[2]) begin                     // a GPR read (or, with FPR, an FP register)
                        r = rnd(FPR ? 64 : 32);
                        ar_read(gpr_regno(r), v);
                        ev(EV_GPR, 64'(r), v);
                    end
                    2: if (feat_i[2]) begin                         // a CSR read
                        r = rnd(N_CSR_READS);
                        ar_read({4'b0, csr_read_addr(r)}, v);
                        ev(EV_CSR, {52'b0, csr_read_addr(r)}, v);
                    end
                    3: if (feat_i[2]) begin                         // read a GPR (or FP register) and write it back
                        r = 1 + rnd(FPR ? 63 : 31);
                        ar_read(gpr_regno(r), v);
                        ar_write(gpr_regno(r), v);
                        ev(EV_WRITE, 64'(r), v);
                    end
                    4: if (feat_i[2] && reserved) begin              // random values into the script's own registers
                        r  = 22 + rnd(2);
                        lo = next32(0);
                        hi = next32(0);
                        ar_write(gpr_regno(r), {hi, lo});
                        ar_read(gpr_regno(r), back);
                        ev(EV_WRITE, 64'(r), back);
                    end
                    5: if (feat_i[2]) begin                         // dscratch0/1
                        r  = rnd(2);
                        lo = next32(0);
                        hi = next32(0);
                        ar_write({4'b0, (r == 0) ? CSR_DSCRATCH0 : CSR_DSCRATCH1}, {hi, lo});
                        ar_read({4'b0, (r == 0) ? CSR_DSCRATCH0 : CSR_DSCRATCH1}, back);
                        ev(EV_WRITE, 64'(r), back);
                    end
                    6: if (feat_i[5]) begin                         // a Program Buffer run
                        pb_run(rnd(FPR ? 16 : 15), reserved);
                    end
                    default: if (feat_i[2]) begin
                        ar_read({4'b0, CSR_MINSTRET}, v);
                        ev(EV_MINSTRET, v, 64'b0);
                    end
                endcase
            end

            // make progress certain after a spontaneous entry
            newdcsr = dcsr;
            if (cause == 3'd1) begin                                // an EBREAK entry: let it trap normally next
                newdcsr[15] = 1'b0;
                newdcsr[13] = 1'b0;
                newdcsr[12] = 1'b0;
            end
            // A trigger lives for one phase only: disable both whenever the script may have armed one. An
            // action-0 trigger (a breakpoint exception whose handler skips the instruction) that stayed armed
            // on a counted loop's decrement would keep the loop from ever ending, and a trigger entry has to
            // be disabled anyway or the resume would enter debug again at the same instruction.
            if (feat_i[4]) begin
                ar_write({4'b0, CSR_TSELECT}, 64'd0);
                ar_write({4'b0, CSR_TDATA1},  64'd0);
                ar_write({4'b0, CSR_TSELECT}, 64'd1);
                ar_write({4'b0, CSR_TDATA1},  64'd0);
            end

            // what to run with next
            if (wind_down) begin
                newdcsr[15] = 1'b0; newdcsr[13] = 1'b0; newdcsr[12] = 1'b0; newdcsr[2] = 1'b0;
                steps_left = 0;
                last_phase = 1'b1;
            end else begin
                if (steps_left > 0) begin
                    steps_left = steps_left - 1;
                    newdcsr[2] = 1'b1;
                end else begin
                    newdcsr[2] = 1'b0;
                    if (feat_i[1] && rnd(4) == 0) begin              // start a short run of single steps
                        steps_left = rnd(3);
                        newdcsr[2] = 1'b1;
                    end
                end
                if (feat_i[3] && rnd(2) == 0) begin                   // arm EBREAK-to-debug for some privilege levels
                    k   = rnd(4);                                     // all privilege levels, or a random subset
                    b15 = rnd(2);
                    b13 = rnd(2);
                    b12 = rnd(2);
                    newdcsr[15] = (k == 0) || (b15 == 0);
                    newdcsr[13] = (k == 0) || (b13 == 0);
                    newdcsr[12] = (k == 0) || (b12 == 0);
                end
                if (feat_i[2] && rnd(4) == 0) newdcsr[10] = ~newdcsr[10];    // stopcount
                if (feat_i[4] && rnd(3) == 0) begin                   // arm one trigger a few instructions ahead
                    slot = rnd(2);
                    cnt  = rnd(11);
                    ar_write({4'b0, CSR_TSELECT}, 64'(slot));
                    ar_write({4'b0, CSR_TDATA2},  dpc + 64'(2 * cnt));
                    v = 64'b0;
                    k = rnd(2);
                    // action: 1 debug entry, or 0 breakpoint trap -- only where it is safe: outside the set-up
                    // code (below 0x40) and the trap handler (from 0x8000), whose own instructions must not
                    // be skipped or trapped on
                    v[12] = (k == 0) || !feat_i[8] || (dpc < 64'h40) || (dpc >= 64'h8000);
                    v[6]  = 1'b1;                                     // m
                    v[4]  = (rnd(2) == 0);                            // s
                    v[3]  = (rnd(2) == 0);                            // u
                    v[2]  = (rnd(4) != 0);                            // execute (clear: a trigger that must never fire)
                    ar_write({4'b0, CSR_TDATA1}, v);
                end
            end
            if (newdcsr != dcsr) begin
                ar_write({4'b0, CSR_DCSR}, newdcsr);
            end
            if (feat_i[7] && feat_i[0] && !last_phase && !wind_down && rnd(8) == 0) hold_across_q = 1'b1;
            if (hold_across_q) o_halt_req = 1'b1;                    // up again before the resume: one retirement, then the next halt
            ev(EV_RESUME, newdcsr, {63'b0, hold_across_q});
            dmi_write(DMI_DMCONTROL, 32'h4000_0001);                 // resumereq
        end
    endtask

    // ------------------------------------------------------------------
    // the script
    // ------------------------------------------------------------------
    task automatic script;
        integer phases, phase, gap, n;
        logic [63:0] target;
        logic        raised;
        begin
            rng = (seed_i == 32'b0) ? 32'h5EED_D0C5 : seed_i;
            phases        = 6 + rnd(20);
            steps_left    = 0;
            hold_across_q = 1'b0;
            last_phase    = 1'b0;
            dmi_write(DMI_DMCONTROL, 32'h0000_0001);                 // dmactive
            for (phase = 0; phase < phases; phase = phase + 1) begin
                last_phase = (phase == phases - 1);
                gap    = 8 + rnd(integer'(density_i) * 8 + 1);
                target = retired_q + 64'(gap);
                raised = hold_across_q;                              // the level is already up after a held resume
                hold_across_q = 1'b0;
                while (1) begin
                    tick;
                    if (debug_mode_i) break;
                    if (!raised && feat_i[0] && retired_q >= target
                            && (max_retire_i == 64'b0 || retired_q + 64'(PHASE_MARGIN) <= max_retire_i)) begin
                        if (late_i) tick;
                        o_halt_req = 1'b1;
                        raised = 1'b1;
                    end
                end
                o_halt_req = 1'b0;                                   // the request is spent: the hart is halted
                halted_phase;                                        // (raises it again before a held resume)
                // the resume takes effect at the next edge; do not look for the next halt before it has
                tick;
                n = 0;
                while (debug_mode_i) begin
                    tick;
                    n = n + 1;
                    if (n > 5000) fail("the hart is still in Debug Mode long after a resume");
                end
            end
        end
    endtask

    initial begin
        o_reg_addr  = 7'b0;
        o_reg_wdata = 32'b0;
        o_reg_we    = 1'b0;
        o_halt_req  = 1'b0;
        o_ev_valid  = 1'b0;
        o_ev_kind   = 4'b0;
        o_ev_order  = 64'b0;
        o_ev_a      = 64'b0;
        o_ev_b      = 64'b0;
        rng         = 32'h1;
        while (rst !== 1'b0) @(posedge clk);
        #1;
        if (mode_i != 32'b0) script;
    end
endmodule
