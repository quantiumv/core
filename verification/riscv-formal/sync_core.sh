#!/bin/bash
# sync_core.sh fsm|pipe -- copy a core's RTL, the shared wrapper and its
# checks.cfg into the riscv-formal checkout and regenerate its checks.
# Run under WSL. The checkout defaults to ~/riscv-formal (override with
# RVFORMAL=...); it carries this repo's local patches, see
# quantiumv/README.md. Regenerating deletes the core's old results.
#
#   fsm  -> $RVFORMAL/cores/quantiumv       (design/core.sv)
#   pipe -> $RVFORMAL/cores/quantiumv_pipe  (design/pipe/core_pipe.sv)
#
# Then run the checks with run_sweep.sh.
set -eu
cd "$(dirname "$0")/../.."
REPO=$(pwd)
RVFORMAL=${RVFORMAL:-$HOME/riscv-formal}

case "${1:-}" in
    fsm)
        NAME=quantiumv
        FILES="design/alu.sv design/decoder.sv design/register_file.sv design/csr_file.sv
               design/divider.sv design/c_expand.sv design/core.sv" ;;
    pipe)
        NAME=quantiumv_pipe
        FILES=$(grep -E '^design/(pipe/|decoder\.sv|alu\.sv|c_expand\.sv|csr_file\.sv|register_file\.sv)' \
                    verification/regress/pipe_design_files.list) ;;
    *) echo "usage: sync_core.sh fsm|pipe" >&2; exit 2 ;;
esac

DST="$RVFORMAL/cores/$NAME"
rm -rf "$DST/design" "$DST/checks"
mkdir -p "$DST/design/pipe"
for f in $FILES; do
    cp "$REPO/$f" "$DST/${f}"
done
cp -r "$REPO/design/defaults" "$DST/design/"
cp "$REPO/verification/riscv-formal/quantiumv/wrapper.sv" "$DST/"
cp "$REPO/verification/riscv-formal/$NAME/checks.cfg" "$DST/"
(cd "$DST" && python3 ../../checks/genchecks.py > /dev/null)
echo "synced $NAME: $(ls "$DST/checks"/*.sby | wc -l) checks in $DST/checks"
