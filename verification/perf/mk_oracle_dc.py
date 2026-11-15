#!/usr/bin/env python3
"""mk_oracle_dc.py SRC DST -- make the ideal in-core D$ oracle (run_perf.sh --oracle dc, O5.0) from design/pipe/qv_lsu.sv.

The copy completes a plain load from RAM in the cycle it could start its bus access (start_raw: at the head, or early;
translated, aligned, allowed by the PMP, no store-buffer match), with the dword read from the memory array named by the
define QV_ORACLE_DC_MEM, and never takes the bus: a D$ inside the core that never misses. It bounds what O5a can gain
and checks the model's 'dc nomiss' (rule M0). It is generated at build time, so it follows qv_lsu.sv; every edit below
must match exactly once, or this script fails and the anchors need updating.
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
    "// verification/perf/mk_oracle_dc.py: a plain RAM load completes in the cycle it could start, from\n"
    "// `QV_ORACLE_DC_MEM, without the bus (an ideal in-core D$). A timing model, not a correct core.\n")
sub("    wire start     = start_raw && ",
    "    wire done_dc   = start_raw && ram_ld;                              // ORACLE: the ideal D$ answers now\n"
    "    wire [63:0] dc_word = `QV_ORACLE_DC_MEM[pa[25:3]];\n"
    "    wire start     = start_raw && !done_dc && ")
sub("    assign o_bus_busy     = start_raw || in_bus;",
    "    assign o_bus_busy     = (start_raw && !done_dc) || in_bus;")
sub("    assign handoff    = HANDOFF && (done_bus || post_done);",
    "    assign handoff    = HANDOFF && (done_bus || post_done || done_dc);")
sub("    wire [63:0] shifted = wb_mem_dat_i >> {addr_q[2:0], 3'b000};",
    "    wire [63:0] shifted = (done_dc ? dc_word : wb_mem_dat_i) >> {addr_q[2:0], 3'b000};")
sub("        o_wb.valid = done_bus || done_nobus || post_done;",
    "        o_wb.valid = done_bus || done_nobus || post_done || done_dc;")
sub("        else if (done_bus && !wb_mem_err_i && kind_rd && !sc_q) o_wb.value = load_value;",
    "        else if ((done_dc || (done_bus && !wb_mem_err_i)) && kind_rd && !sc_q) o_wb.value = load_value;")
sub("                    else if (done_nobus || post_done) state_q <= S_IDLE;",
    "                    else if (done_nobus || post_done || done_dc) state_q <= S_IDLE;")
sub("            if (done_bus || done_nobus || post_done) begin",
    "            if (done_bus || done_nobus || post_done || done_dc) begin")
sub("                                     : done_bus ? wb_mem_dat_i : 64'b0;",
    "                                     : done_bus ? wb_mem_dat_i : done_dc ? dc_word : 64'b0;")
open(dst, 'w').write(s)
