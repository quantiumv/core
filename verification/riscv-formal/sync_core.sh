#!/bin/bash
# sync_core.sh fsm|pipe|pipe-full|pipe-amo -- copy a core's RTL, the shared wrapper
# and its checks.cfg into the riscv-formal checkout and regenerate its
# checks. Run under WSL. The checkout defaults to ~/riscv-formal (override
# with RVFORMAL=...); it carries this repo's local patches, see
# quantiumv/README.md. Regenerating deletes the core's old results.
#
#   fsm       -> $RVFORMAL/cores/quantiumv       (design/core.sv)
#   pipe      -> $RVFORMAL/cores/quantiumv_pipe  (design/pipe/core_pipe.sv)
#   pipe-full -> $RVFORMAL/cores/quantiumv_pipe_full: the same without
#                QV_FORMAL_SMALL (full-size ROB and IQ), for spot checks
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
case "${1:-}" in
    fsm)
        NAME=quantiumv
        FILES="design/alu.sv design/decoder.sv design/register_file.sv design/csr_file.sv
               design/divider.sv design/c_expand.sv design/core.sv" ;;
    pipe|pipe-full|pipe-amo)
        NAME=quantiumv_pipe
        [ "$1" == "pipe-full" ] && SUFFIX=_full
        [ "$1" == "pipe-amo" ] && NAME=quantiumv_pipe_amo
        FILES=$(grep -E '^design/(pipe/|decoder\.sv|alu\.sv|c_expand\.sv|csr_file\.sv|register_file\.sv|divider\.sv)' \
                    verification/regress/pipe_design_files.list) ;;
    *) echo "usage: sync_core.sh fsm|pipe|pipe-full|pipe-amo" >&2; exit 2 ;;
esac

DST="$RVFORMAL/cores/$NAME$SUFFIX"
rm -rf "$DST/design" "$DST/checks"
mkdir -p "$DST/design/pipe"
for f in $FILES; do
    cp "$REPO/$f" "$DST/${f}"
done
cp -r "$REPO/design/defaults" "$DST/design/"
cp "$REPO/verification/riscv-formal/quantiumv/wrapper.sv" "$DST/"
cp "$REPO/verification/riscv-formal/$NAME/checks.cfg" "$DST/"
[ -z "$SUFFIX" ] || sed -i 's/ -D QV_FORMAL_SMALL//' "$DST/checks.cfg"
if [ "$1" != "fsm" ]; then
    # the cfg's read_slang line takes the file list from here, not a copy of its own
    RTL=""
    for f in $FILES; do RTL="$RTL @basedir@/cores/@core@/$f"; done
    sed -i "s#@PIPE_RTL@#${RTL# }#" "$DST/checks.cfg"
fi
(cd "$DST" && python3 ../../checks/genchecks.py > /dev/null)
echo "synced $NAME$SUFFIX: $(ls "$DST/checks"/*.sby | wc -l) checks in $DST/checks"
