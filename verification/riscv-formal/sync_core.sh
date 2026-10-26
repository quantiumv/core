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
        # the reference's seven files and its macros header, flat in design/ (the cfg lists them there)
        FILES="verification/reference/ref_alu.sv verification/reference/ref_decoder.sv
               verification/reference/ref_register_file.sv verification/reference/ref_csr_file.sv
               verification/reference/ref_divider.sv verification/reference/ref_c_expand.sv
               verification/reference/ref_core.sv verification/reference/ref_macros.svh" ;;
    pipe|pipe-full|pipe-amo|pipe-sv39|pipe-sb)
        NAME=quantiumv_pipe
        [ "$1" == "pipe-full" ] && SUFFIX=_full
        [ "$1" == "pipe-sb" ] && SUFFIX=_sb
        [ "$1" == "pipe-sv39" ] && SUFFIX=_sv39
        [ "$1" == "pipe-amo" ] && NAME=quantiumv_pipe_amo
        FILES=$(grep -E '^design/(pipe/|decoder\.sv|alu\.sv|c_expand\.sv|csr_file\.sv|register_file\.sv|divider\.sv)' \
                    verification/regress/design_files.list) ;;
    *) echo "usage: sync_core.sh ref|pipe|pipe-full|pipe-amo|pipe-sv39|pipe-sb" >&2; exit 2 ;;
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
[ "$1" != "pipe-sb" ] || sed -i 's/ -D QV_FORMAL_SMALL/ -D QV_FORMAL_SMALL -D QV_PIPE_PMA_RAM_SIZE=2147483648/' "$DST/checks.cfg"
if [ -z "$REF" ]; then
    # the cfg's read_slang line takes the file list from here, not a copy of its own
    RTL=""
    for f in $FILES; do RTL="$RTL @basedir@/cores/@core@/$f"; done
    sed -i "s#@PIPE_RTL@#${RTL# }#" "$DST/checks.cfg"
fi
(cd "$DST" && python3 ../../checks/genchecks.py > /dev/null)
echo "synced $NAME$SUFFIX: $(ls "$DST/checks"/*.sby | wc -l) checks in $DST/checks"
