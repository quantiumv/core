#!/bin/bash
# check_copies.sh -- the reference's renamed copies (gen_copies.sh) still match their design/ originals.
# Nothing tests the copies themselves (the FPU's unit tests run on design/pipe/), so this is what keeps them honest:
# a copy that differs from what gen_copies.sh makes now was edited, or its original changed without the copy.
set -u
cd "$(dirname "$0")" || exit 1
T=$(mktemp -d)
bash gen_copies.sh "$T"
bad=0
for f in "$T"/*.sv; do
    b=$(basename "$f")
    if ! diff -q <(tr -d '\r' < "$f") <(tr -d '\r' < "$b") > /dev/null 2>&1; then
        echo "DIFFERS: $b (rerun gen_copies.sh if the design/ change is meant for the reference too)"
        bad=1
    fi
done
rm -rf "$T"
[ "$bad" == "0" ] && echo "check_copies: all $(ls ref_fp*.sv ref_exu_fpu.sv ref_csr_file.sv ref_csr_exists.sv 2>/dev/null | wc -l) copies match" || exit 1
