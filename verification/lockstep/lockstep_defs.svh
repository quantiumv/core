`ifndef QV_LOCKSTEP_DEFS_SVH
`define QV_LOCKSTEP_DEFS_SVH

/*
 * Shared constants for the P3.4 lockstep harness (pipelining track plan,
 * section P3.4). Included by every lockstep_*.sv file under
 * verification/lockstep.
 */

// Flat image size: matches verification/lockstep/gen/qvgen.py's own 1 MiB
// image (gen/link.ld: _stack_top = 0x100000) and testbench/rvfi_tracer.sv's
// NUM_WORDS=131072 convention. wb4_sram.sv is 64-bit-word addressed.
`define QV_LOCKSTEP_RAM_WORDS 131072
`define QV_LOCKSTEP_RAM_BYTES 32'h00100000

// MMIO window: widened to match design/wb_addr_decoder.sv's own real
// UART window (0x0400_8000-0x0400_FFFF, 32KB -- see that file's header)
// rather than some free choice, after firmware/hello.c (part of
// fw.list's corpus) turned out to write its output character straight
// to 0x04008000 -- the real 16550's THR at offset 0 -- expecting the
// real soc.sv memory map, not qvgen.py's. Any address in this window
// that isn't one of the specific registers below is a harmless dummy:
// writes are silently accepted (acked, no state change), reads return
// 0 -- exactly so a program written against either memory-map
// convention never bus-faults here.
`define QV_LOCKSTEP_MMIO_BASE   32'h04008000
`define QV_LOCKSTEP_MMIO_SIZE   32'h00008000
// qvgen.py's M/S-mode trap handlers already hardcode 0x0400F004 as
// "write 1 here to clear the injected interrupt" (gen/qvgen.py:608,
// 718) as a forward reference to this harness, so that address is
// load-bearing, not a free choice. It shares an 8-byte-aligned dword
// with the SET register at 0x0400F000 (SET in the low 4 bytes, CLR in
// the high 4), matching how a 64-bit Wishbone data bus presents a
// 32-bit `sw`.
`define QV_LOCKSTEP_MAGIC_SET   32'h0400F000
`define QV_LOCKSTEP_MAGIC_CLR   32'h0400F004
// Dummy UART: THR at the real 16550 base (firmware/hello.c's own
// target); LSR at qvgen.py's own chosen offset (never targeted by
// qvgen.py today, but kept for symmetry -- a stray LSR poll from
// either convention should never bus-fault either).
`define QV_LOCKSTEP_UART_THR      32'h04008000
`define QV_LOCKSTEP_UART_LSR      32'h0400F018
`define QV_LOCKSTEP_UART_LSR_THRE 8'h60   // THRE (bit5) and TEMT (bit6) always set

// Fixed-depth rings (Verilator-compatible: no dynamic/fork constructs in
// the compare path).
`define QV_LOCKSTEP_REC_DEPTH   128   // retirement-record ring, per side
`define QV_LOCKSTEP_WR_DEPTH    64    // bus-write-log ring, per side
`define QV_LOCKSTEP_RD_DEPTH    64    // mmio-read-log ring, per side
`define QV_LOCKSTEP_HIST_DEPTH  16    // "last N matched" report history
`define QV_LOCKSTEP_AHEAD_MAX   64    // pause a side's clock past this many unconsumed records

`endif
