# Module proofs for core_pipe

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
| `qv_lsu` (`lsu_props.sv`) | An access starts only when its uop is the ROB head, at most once per uop, and never for a misaligned uop. A started access stays on the bus, unchanged, until answered. Each uop completes at most once, with its own tag. A misaligned uop completes with cause 4/6 (6 for every atomic). A load or LR makes one read, a store one write. An SC makes one write, and only when the reservation matched its address as it became the head; otherwise it completes with no request. An AMO makes a read and then, only after a clean unflushed read, one write to the same address, never a third request. `wb_mem_lock_o` is up exactly from an AMO's first request cycle to the response of its last, with no gap, and never otherwise. |

`--mutants` checks that the properties catch these mutants:
- the pre-fix `qv_fetch` (before `ade0d1c`), whose 1-bit epoch let a stale response through after two redirects;
- a fetch that ignores the stale bit, ignores hold, or abandons a request on redirect;
- an LSU that ignores the ROB head, puts misaligned accesses on the bus, re-issues after a response, or abandons a request on flush;
- an LSU whose SC ignores the reservation, whose lock has a gap or is held for every access, whose AMO writes after a faulting or flushed read, or whose AMO never writes.

The property modules read some internals hierarchically (`dut.*`), as
lemmas for the induction.
