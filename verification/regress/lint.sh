#!/bin/bash
# Verilator lint pass, checked-in version of the command README.md
# documents under "A Verilator lint pass over the full SoC". Run under
# WSL bash: `wsl bash -lc "verification/regress/lint.sh"`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

CORE=pipe
EXTRA_DEFINES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --core) CORE="$2"; shift 2 ;;
        --defines) for d in $2; do EXTRA_DEFINES="$EXTRA_DEFINES -D$d"; done; shift 2 ;;   # e.g. "QV_FPU_EN=1"
        -h|--help) echo "Usage: lint.sh [--core pipe|ref] [--defines \"A=1 B=0\"]"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

CORE_DEFINE=""
case "$CORE" in
    ref)
        DESIGN_LIST="verification/regress/ref_design_files.list"
        TOP=soc
        CORE_DEFINE="-DQV_REF_AS_CORE"
        ;;
    pipe)
        DESIGN_LIST="verification/regress/design_files.list"
        TOP=soc
        ;;
    *)
        echo "Unknown --core: $CORE (expected pipe or ref; the FSM core is ref)" >&2; exit 1 ;;
esac

DESIGN_FILES=""
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -n "$line" ] || continue
    DESIGN_FILES="$DESIGN_FILES $line"
done < "$DESIGN_LIST"

verilator --lint-only -Wall $CORE_DEFINE $EXTRA_DEFINES -Idesign -Idesign/defaults -Iverification/reference \
    --top-module "$TOP" $DESIGN_FILES
