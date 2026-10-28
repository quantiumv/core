#!/bin/bash
# gen_copies.sh [OUTDIR] -- the reference's copies of design/ files it shares behaviour with, made by renaming only.
#
# The F/D feature addition (README.md, "Feature additions") gave the reference the same FPU as the pipelined core,
# through private copies, as the P3 freeze did for the integer leaves: a later change to design/ does not reach the
# reference unless it is copied over on purpose. These copies differ from their originals only in names:
#   design/csr_file.sv              -> ref_csr_file.sv      (module csr_file -> ref_csr_file)
#   design/pipe/qv_fp_dec.sv        -> ref_fp_dec.sv
#   design/pipe/qv_fpu_round.sv     -> ref_fpu_round.sv
#   design/pipe/qv_fpu_pipe.sv      -> ref_fpu_pipe.sv
#   design/pipe/qv_fpu_divsqrt.sv   -> ref_fpu_divsqrt.sv
#   design/pipe/qv_exu_fpu.sv       -> ref_exu_fpu.sv
#   design/pipe/qv_fprf.sv          -> ref_fprf.sv
#   design/pipe/qv_pkg.sv's F/D section (between its "F/D section" markers) -> ref_fpu_pkg.sv (package ref_fpu_pkg)
# (ref_c_expand.sv is not here: it carries mutant 8's hook, so its Zcd arms were copied by hand.)
#
# With no argument the copies are written here; check_copies.sh writes them to a temporary directory and diffs.
set -u
cd "$(dirname "$0")" || exit 1
REPO=$(cd ../.. && pwd)
OUT=${1:-.}

ren() {
    sed -e 's/\bqv_pkg\b/ref_fpu_pkg/g' -e 's/\bqv_fp_dec\b/ref_fp_dec/g' -e 's/\bqv_fpu_\([a-z]*\)\b/ref_fpu_\1/g' \
        -e 's/\bqv_exu_fpu\b/ref_exu_fpu/g' -e 's/\bqv_fprf\b/ref_fprf/g' "$@"
}

sed -e 's/^module csr_file\b/module ref_csr_file/' -e 's/^endmodule: csr_file\b/endmodule: ref_csr_file/' \
    "$REPO/design/csr_file.sv" > "$OUT/ref_csr_file.sv"
for f in qv_fp_dec qv_fpu_round qv_fpu_pipe qv_fpu_divsqrt qv_exu_fpu qv_fprf; do
    ren "$REPO/design/pipe/$f.sv" > "$OUT/$(echo $f | sed -e 's/^qv_fp_dec$/ref_fp_dec/' -e 's/^qv_/ref_/').sv"
done
{
    echo "// SPDX-License-Identifier: MIT"
    echo ""
    echo "// ref_fpu_pkg -- the F/D section of design/pipe/qv_pkg.sv, renamed (made by gen_copies.sh: do not edit)."
    echo "package ref_fpu_pkg;"
    echo "    localparam int QV_ROB_TAG_W = 4;           // qv_pkg's tag width (ROB of 8: index + wrap bit)"
    sed -n '/F\/D section begin/,/F\/D section end/p' "$REPO/design/pipe/qv_pkg.sv"
    echo "endpackage"
} > "$OUT/ref_fpu_pkg.sv"
