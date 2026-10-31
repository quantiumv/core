// SPDX-License-Identifier: MIT

/*
 * ref_csr_exists -- whether a CSR address exists (errata E10). An access to
 * one that does not is an illegal instruction, from every privilege level;
 * decode ORs that with its other illegal-instruction rules (privilege,
 * read-only write, the debug CSRs outside Debug Mode, TVM, FS Off, the
 * counter enables). Purely combinational. The reference uses a renamed copy
 * (verification/reference/gen_copies.sh), so both cores trap on the same set.
 *
 * The set is Sail's under the ACT configs (verification/reference/probes/
 * csr_table.txt), with two exceptions:
 *   - mcycle and minstret always exist: Sm requires them, and these cores
 *     have always had them (Sail ties them to Zicntr);
 *   - the trigger CSRs 0x7A1-0x7A4 exist (they are legal only in Debug Mode,
 *     a separate rule; Sail has only tselect).
 * What exists:
 *   fflags, frm, fcsr                0x001-0x003   with the FPU
 *   sstatus, sie, stvec, scounteren  0x100, 0x104-0x106
 *   senvcfg                          0x10A
 *   sscratch, sepc, scause, stval, sip  0x140-0x144
 *   satp                             0x180
 *   mstatus .. mcounteren            0x300-0x306
 *   menvcfg                          0x30A
 *   mcountinhibit                    0x320          reads 0, ignores writes
 *   mscratch, mepc, mcause, mtval, mip  0x340-0x344
 *   pmpcfg0, pmpcfg2                 0x3A0, 0x3A2   (pmpcfg2 reads 0)
 *   pmpaddr0-15                      0x3B0-0x3BF    (4-15 read 0)
 *   tselect .. tinfo                 0x7A0-0x7A4
 *   dcsr, dpc, dscratch0/1           0x7B0-0x7B3
 *   mcycle, minstret                 0xB00, 0xB02
 *   cycle, time, instret             0xC00-0xC02    with Zicntr
 *   mvendorid .. mconfigptr          0xF11-0xF15    (mconfigptr reads 0)
 * Everything else does not: the HPM counters and events, the RV32-only high
 * halves (mstatush, menvcfgh, cycleh, ...), the hypervisor CSRs, Sstc,
 * Smstateen, mseccfg, seed, tcontrol.
 */
module ref_csr_exists #(
    parameter bit FP_EN     = 1'b0,
    parameter bit ZICNTR_EN = 1'b0
) (
    input  logic [11:0] i_addr,
    output logic        o_exists
);
    wire [11:0] a = i_addr;

    assign o_exists = (FP_EN && a >= 12'h001 && a <= 12'h003)
                   || a == 12'h100 || (a >= 12'h104 && a <= 12'h106) || a == 12'h10A
                   || (a >= 12'h140 && a <= 12'h144) || a == 12'h180
                   || (a >= 12'h300 && a <= 12'h306) || a == 12'h30A || a == 12'h320
                   || (a >= 12'h340 && a <= 12'h344)
                   || a == 12'h3A0 || a == 12'h3A2 || a[11:4] == 8'h3B
                   || (a >= 12'h7A0 && a <= 12'h7A4) || (a >= 12'h7B0 && a <= 12'h7B3)
                   || a == 12'hB00 || a == 12'hB02
                   || (ZICNTR_EN && a >= 12'hC00 && a <= 12'hC02)
                   || (a >= 12'hF11 && a <= 12'hF15);
endmodule: ref_csr_exists
