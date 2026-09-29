#!/bin/bash
# Verifies every ref_*.sv/ref_macros.svh file under verification/reference/
# still matches the checksums recorded at the P3.3 freeze -- catches an
# accidental edit to the frozen reference core. A DELIBERATE fix (a real
# reference bug, confirmed and fixed in both design/core.sv and this
# directory -- see README.md's own "Errata" rule) must regenerate
# MANIFEST.sha256 afterward and add an entry to README.md's errata log;
# this script has no way to tell "deliberate errata" from "accidental
# edit" itself, so that's a human (or review) step, not something this
# script enforces.
#
# Run under WSL bash: `wsl bash -lc "verification/reference/check_manifest.sh"`
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

sha256sum -c MANIFEST.sha256
