# Module proofs for the pipelined core

SymbiYosys proofs of single `design/pipe/` units. They complement
riscv-formal (`../../riscv-formal/`), which checks the whole core against
the ISA but only to a bounded depth.

```sh
verification/formal/pipe/run.sh            # proofs
verification/formal/pipe/run.sh --mutants  # plus: known-bad versions must fail
```

Each unit has three tasks:
- `prove`: k-induction, so the property holds at every depth;
- `bmc`: a deep cross-check;
- `cover`: shows the properties aren't vacuous.

The bus model is a registered Wishbone slave: it answers a request that
was on the bus, unanswered, the previous cycle.

| Unit | Properties |
|---|---|
| `qv_fetch` (`fetch_props.sv`) | A request is never abandoned or changed before its response. Every entry handed out is the next one expected: the latest redirect's target, then each following dword, with the data of its own address. So no stale, dropped or duplicated response gets through. While held (FENCE.I), nothing new starts. |
| `qv_dbg` (`dbg_props.sv`) | The Debug Mode flags and the Program Buffer injector. A Program Buffer run implies Debug Mode, even when a start and a resume arrive in the same cycle (the resume wins). A resume is accepted only while halted and not running a Program Buffer, and the Debug Module owns regfile0's port and the CSR port exactly when halted with no run. A word is injected only during a run, with room in the queue, and never while the previous one is still in flight. The word index starts at 0 with the run, counts the retirements and stops at the run's last. `stepping` is loaded from dcsr.step by an accepted resume and consumed by a halt/step entry. |
| `qv_lsu` (`lsu_props.sv`) | An access starts only when its uop is the ROB head, at most once per uop, and never for a misaligned uop. A started access stays on the bus, unchanged, until answered. Each uop completes at most once, with its own tag. A misaligned uop completes with cause 4/6 (6 for every atomic). A load or LR makes one read, a store one write. An SC makes one write, and only when the reservation matched its address as it became the head; otherwise it completes with no request. An AMO makes a read and then, only after a clean unflushed read, one write to the same address, never a third request. `wb_mem_lock_o` is up exactly from an AMO's first request cycle to the response of its last, with no gap, and never otherwise. |
| `qv_ptw` (`ptw_props.sv`) | The page-table walker, with free clients, PMP configuration, LSU busy flag and bus answers (ack and err at any time, even with no beat of the walker's in flight). A PTE read stays on the bus, unchanged, until it is answered, and cyc is low in the response cycle. A beat starts only after a cycle with the LSU idle and only for an address the PMP allows at S privilege. A walk is at most three beats. A walk its client cancelled at any time since it was accepted never reports a result (so nothing is filled behind a cancel). A result that came from reading a PTE needs a response to a beat of the walker's own. |
| `qv_exu_fpu` (`fpu_props.sv`) | The FP unit's control, built with `QV_FORMAL_FPU_ABSTRACT` (values and flags free; the arithmetic is checked against TestFloat and Sail vectors, `verification/fpu/`). Nothing is written back in a flush cycle. A pipeline op is written back exactly 4 cycles after its request unless a flush comes first. Any other writeback is the divide or square root in flight, so every writeback belongs to one live op and a killed one never comes back, even when its tag is reused at once. The side unit reports itself free exactly when nothing is in it, and a finished divide is written back in the first cycle the pipeline leaves the port. |

The translation paths of `qv_fetch` and `qv_lsu` (the XL phase, the translated address, PMP on it) are covered by
unit testbenches with mutation specs, by the end-to-end lockstep against `ref_core` and by the Bare-mode proofs
above (translation is off at the harness's default inputs); `qv_pte`, `qv_tlb` and `qv_xlate` likewise. The
riscv-formal sweeps build the core without translation (`QV_FORMAL_NO_SV39`).

`--mutants` checks that the properties catch these mutants:
- the pre-fix `qv_fetch` (before `ade0d1c`), whose 1-bit epoch let a stale response through after two redirects;
- a fetch that ignores the stale bit, ignores hold, or abandons a request on redirect;
- an LSU that ignores the ROB head, puts misaligned accesses on the bus, re-issues after a response, or abandons a request on flush;
- an LSU whose SC ignores the reservation, whose lock has a gap or is held for every access, whose AMO writes after a faulting or flushed read, or whose AMO never writes;
- a walker whose cancelled walk still reports (or whose stale result is still decoded), that starts a beat while the LSU is busy or for an address the PMP denies, that holds cyc into the response cycle or drops it on a cancel;
- an FP unit that writes back in a flush cycle, lets a finished divide take the port from the pipeline, reports the divide unit free while busy or busy for too short, keeps a stage across a flush, does not kill a divide on a flush, does not hold a finished divide, or skips or mis-tags a pipeline stage;
- a debug unit that accepts a start outside Debug Mode, lets a start beat a same-cycle resume, accepts a resume during a run, injects while a word is in flight or with no room, moves the word index at the run's last word, hands the ports to the Debug Module during a run, or never arms the step.

The property modules read some internals hierarchically (`dut.*`), as
lemmas for the induction.
