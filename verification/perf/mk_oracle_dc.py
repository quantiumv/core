#!/usr/bin/env python3
"""mk_oracle_dc.py SRC DST -- make the ideal in-core D$ oracle (run_perf.sh --oracle dc, O5.0) from design/pipe/qv_lsu.sv.

The copy is the LSU's own D$ arm (DC_EN, O5a) with a D$ that always hits: every plain load from RAM that could start
(at the head, or early; translated, aligned, allowed by the PMP, no store-buffer match) completes in that cycle with
the dword read from the memory array named by the define QV_ORACLE_DC_MEM, never refills and never takes the bus. So
it has the timing of the real D$ arm (the handoff, the store buffer not yielding to a hit) without its misses: an upper
bound for O5a, and the check of the model's 'dc nomiss' (rule M0). It is generated at build time, so it follows
qv_lsu.sv; every edit below must match exactly once, or this script fails and the anchors need updating.
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()


def sub(old, new):
    global s
    n = s.count(old)
    if n != 1:
        sys.exit('mk_oracle_dc.py: %d matches for: %s' % (n, old.strip()[:90]))
    s = s.replace(old, new)


sub("// SPDX-License-Identifier: MIT\n",
    "// SPDX-License-Identifier: MIT\n"
    "// ORACLE, TESTBENCH ONLY (run_perf.sh --oracle dc), generated from design/pipe/qv_lsu.sv by\n"
    "// verification/perf/mk_oracle_dc.py: its D$ arm with a D$ that always hits, read from `QV_ORACLE_DC_MEM.\n"
    "// A timing model, not a correct core.\n")
sub("    wire dc_ld     = DC_EN && ram_ld;", "    wire dc_ld     = ram_ld;                                  // ORACLE: every RAM load")
sub("    wire done_dc   = dc_go && i_dc_hit && !i_dc_busy;", "    wire done_dc   = dc_go;                                   // ORACLE: always a hit")
sub("    wire dc_miss   = dc_go && !i_dc_hit && ", "    wire dc_miss   = 1'b0 && ")
sub("    wire [63:0] rsp_dat = fill_q ? i_dc_fill_dat : done_dc ? i_dc_dat : wb_mem_dat_i;",
    "    wire [63:0] rsp_dat = fill_q ? i_dc_fill_dat : done_dc ? `QV_ORACLE_DC_MEM[pa[25:3]] : wb_mem_dat_i;")
sub("                         && !(dc_ld && i_dc_hit);", "                         && !dc_ld;")
open(dst, 'w').write(s)
