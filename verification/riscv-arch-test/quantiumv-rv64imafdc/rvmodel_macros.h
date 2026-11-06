// rvmodel_macros.h -- DUT-specific macro definitions for the QuantiumV core
// SPDX-License-Identifier: Apache-2.0

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .align 8; .global tohost; tohost: .dword 0;         \
        .align 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

##### STARTUP #####

#define RVMODEL_BOOT

##### TERMINATION #####

// Two independent halt mechanisms are stacked here on purpose:
//  1. A store to `tohost` -- the Sail reference model watches this address
//     and stops as soon as it's written, exactly like riscv-tests/HTIF. This
//     is what makes the *reference model's* signature computation terminate.
//  2. `ebreak` -- QuantiumV has no HTIF concept at all; a plain memory store
//     is invisible to it. `ebreak` is this core's one real simulation-halt
//     mechanism (design/core.sv: sets a permanent `halted` latch, freezes
//     pc). This is what makes the *DUT* terminate. Our SV harness watches
//     `halted` (same convention every existing testbench in this repo
//     uses), then reads back the `tohost` word to learn pass(1)/fail(3).
// The trailing spin loop is a defensive fallback only -- on real QuantiumV
// hardware `ebreak` freezes fetch on the same edge, so it's never reached.
#define RVMODEL_HALT_PASS  \
  li x1, 1                ;\
  la t0, tohost           ;\
  sw x1, 0(t0)            ;\
  sw x0, 4(t0)            ;\
  ebreak                  ;\
  write_tohost_pass_spin: ;\
    j write_tohost_pass_spin ;\

#define RVMODEL_HALT_FAIL \
  li x1, 3                ;\
  la t0, tohost           ;\
  sw x1, 0(t0)            ;\
  sw x0, 4(t0)            ;\
  ebreak                  ;\
  write_tohost_fail_spin: ;\
    j write_tohost_fail_spin ;\

##### Access Fault #####
// This core generates no access faults at all (no PMA/PMP) -- per the
// README this macro "can be omitted if DUT does not generate some/all
// access faults". In practice the generated test content (e.g.
// ExceptionsSm-00.S) references it unconditionally regardless, so it still
// needs a real, harmless address: well inside act_runner_tb.sv's mapped
// SRAM (NUM_WORDS=131072, i.e. 1 MiB) and sail.json's 4 MiB RAM region,
// but far above where any generated test's own code/data footprint
// reaches, so a stray store here is inert padding, not real corruption.
#define RVMODEL_ACCESS_FAULT_ADDRESS 0xF0000

##### IO #####

// No console/UART wired into the ACT harness (plain core + wb4_sram, same
// as every other minimal testbench topology in this repo) -- no-op both.
#define RVMODEL_IO_INIT(_R1, _R2, _R3)

#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

##### Machine Interrupts #####
// No interrupt controller exists in this core (mie/mip/mideleg are real,
// inert CSR storage with zero consumer -- see the U/S/M privilege-mode
// design notes). Latency/delay values are required by check_defines.h but
// are never actually exercised since no test can trigger a real interrupt.
#define RVMODEL_INTERRUPT_LATENCY 1
#define RVMODEL_TIMER_INT_SOON_DELAY 1

#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2)
#define RVMODEL_CLR_MSW_INT(_R1, _R2)

##### Supervisor Interrupts #####
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif // _RVMODEL_MACROS_H
