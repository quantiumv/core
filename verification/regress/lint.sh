#!/bin/bash
# Verilator lint pass, checked-in version of the command README.md
# documents under "A Verilator lint pass over the full SoC". Run under
# WSL bash: `wsl bash -lc "verification/regress/lint.sh"`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

CORE=fsm
while [ $# -gt 0 ]; do
    case "$1" in
        --core) CORE="$2"; shift 2 ;;
        -h|--help) echo "Usage: lint.sh [--core fsm|ref|pipe]"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

case "$CORE" in
    fsm)
        DESIGN_LIST="verification/regress/design_files.list"
        TOP=soc
        ;;
    ref)
        echo "ERROR: --core ref not wired up yet (P3.3)." >&2; exit 1 ;;
    pipe)
        echo "ERROR: --core pipe not wired up yet (P4a)." >&2; exit 1 ;;
    *)
        echo "Unknown --core: $CORE" >&2; exit 1 ;;
esac

DESIGN_FILES=""
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -n "$line" ] || continue
    DESIGN_FILES="$DESIGN_FILES $line"
done < "$DESIGN_LIST"

verilator --lint-only -Wall -Idesign -Idesign/defaults --top-module "$TOP" $DESIGN_FILES
