#!/bin/bash
# sync_core.sh ref|pipe|pipe-full|pipe-amo|pipe-sv39|pipe-sb -- copy a core's RTL, the shared
# wrapper and its checks.cfg into the riscv-formal checkout and regenerate its
# checks. Run under WSL. The checkout defaults to ~/riscv-formal (override
# with RVFORMAL=...); it carries this repo's local patches, see
# quantiumv/README.md. Regenerating deletes the core's old results.
#
#   ref       -> $RVFORMAL/cores/quantiumv       (the frozen multi-cycle reference,
#                verification/reference/ref_*.sv built as `core` by -D QV_REF_AS_CORE)
#   pipe      -> $RVFORMAL/cores/quantiumv_pipe  (the pipelined core, design/pipe/core.sv)
#   pipe-full -> $RVFORMAL/cores/quantiumv_pipe_full: the same without
#                QV_FORMAL_SMALL (full-size ROB and IQ), for spot checks
#   pipe-sv39 -> $RVFORMAL/cores/quantiumv_pipe_sv39: with address translation
#                (the other pipe models are built with QV_FORMAL_NO_SV39: no
#                walker, no TLBs, satp pinned Bare by the checks' assumptions),
#                one entry in each TLB; run only the checks that are cheap with
#                satp free (see quantiumv_pipe/README.md), liveness and hang
#                excluded: a walk takes longer than their window
#   pipe-sb   -> $RVFORMAL/cores/quantiumv_pipe_sb: the same as pipe, with the core told a RAM window
#                (the first 2 GiB), so the store buffer really takes stores: in the other models the window is empty and
#                it never does. The wrapper then assumes a drain beat gets no bus error. Run the checks that see the
#                drain (liveness, hang, the store instructions, cover, causal; see quantiumv_pipe/README.md)
#   pipe-fpu  -> $RVFORMAL/cores/quantiumv_pipe_fpu: the same as pipe with F/D built in, the FPU's datapath and the
#                FP registers' reads free (QV_FORMAL_FPU_ABSTRACT): no FP check exists; this shows that FP traffic
#                keeps the integer state consistent (run reg, causal, unique, pc_fwd/pc_bwd, ill, cover, csrc_any_*,
#                liveness/hang and the integer load/store and jalr checks)
#   pipe-amo  -> $RVFORMAL/cores/quantiumv_pipe_amo: isa rv64ia, for the 18
#                AMO checks (needs the patch and isa_rv64ia.txt from
#                quantiumv/README.md in the riscv-formal checkout)
#
# Then run the checks with run_sweep.sh.
set -eu
cd "$(dirname "$0")/../.."
REPO=$(pwd)
RVFORMAL=${RVFORMAL:-$HOME/riscv-formal}

SUFFIX=""
REF=""
case "${1:-}" in
    ref)
        NAME=quantiumv
        REF=1
        # the reference's own files (ref_design_files.list) and its macros header, flat in design/ (the cfg lists them)
        FILES="$(grep -E '^verification/reference/' verification/regress/ref_design_files.list) verification/reference/ref_macros.svh" ;;
    pipe|pipe-full|pipe-amo|pipe-sv39|pipe-sb|pipe-fpu)
        NAME=quantiumv_pipe
        [ "$1" == "pipe-full" ] && SUFFIX=_full
        [ "$1" == "pipe-sb" ] && SUFFIX=_sb
        [ "$1" == "pipe-sv39" ] && SUFFIX=_sv39
        [ "$1" == "pipe-fpu" ] && SUFFIX=_fpu
        [ "$1" == "pipe-amo" ] && NAME=quantiumv_pipe_amo
        FILES=$(grep -E '^design/(pipe/|decoder\.sv|alu\.sv|c_expand\.sv|csr_file\.sv|register_file\.sv|divider\.sv)' \
                    verification/regress/design_files.list) ;;
    *) echo "usage: sync_core.sh ref|pipe|pipe-full|pipe-amo|pipe-sv39|pipe-sb|pipe-fpu" >&2; exit 2 ;;
esac

DST="$RVFORMAL/cores/$NAME$SUFFIX"
rm -rf "$DST/design" "$DST/checks"
mkdir -p "$DST/design/pipe"
for f in $FILES; do
    if [ -n "$REF" ]; then cp "$REPO/$f" "$DST/design/$(basename "$f")"; else cp "$REPO/$f" "$DST/${f}"; fi
done
cp -r "$REPO/design/defaults" "$DST/design/"
cp "$REPO/verification/riscv-formal/quantiumv/wrapper.sv" "$DST/"
cp "$REPO/verification/riscv-formal/$NAME/checks.cfg" "$DST/"
[ "$1" != "pipe-full" ] || sed -i 's/ -D QV_FORMAL_SMALL//' "$DST/checks.cfg"
[ "$1" != "pipe-sv39" ] || sed -i 's/ -D QV_FORMAL_NO_SV39//' "$DST/checks.cfg"
[ "$1" != "pipe-fpu" ] || sed -i 's/ -D QV_FORMAL_NO_FPU/ -D QV_FORMAL_FPU_ABSTRACT/' "$DST/checks.cfg"
[ "$1" != "pipe-sb" ] || sed -i 's/ -D QV_FORMAL_SMALL/ -D QV_FORMAL_SMALL -D QV_PIPE_PMA_RAM_SIZE=2147483648/' "$DST/checks.cfg"
if [ -z "$REF" ]; then
    # the cfg's read_slang line takes the file list from here, not a copy of its own
    RTL=""
    for f in $FILES; do RTL="$RTL @basedir@/cores/@core@/$f"; done
    sed -i "s#@PIPE_RTL@#${RTL# }#" "$DST/checks.cfg"
fi
(cd "$DST" && python3 ../../checks/genchecks.py > /dev/null)
echo "synced $NAME$SUFFIX: $(ls "$DST/checks"/*.sby | wc -l) checks in $DST/checks"
