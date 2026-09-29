#!/bin/bash
# Verifies design/defaults/*.sv is append-only relative to the P3.3
# freeze snapshot (verification/reference/defaults_snapshot/) -- these
# files are SHARED (included by reference, not copied) by both
# design/core.sv+decoder.sv and ref_core.sv+ref_decoder.sv (see
# ref_macros.svh's own header comment), so an existing line changing or
# disappearing out from under them would silently change ref_core.sv's
# behavior without ref_core.sv itself ever being touched -- exactly what
# the freeze is supposed to prevent. New content may be added anywhere
# (a new instruction code, a new mask); nothing existing may move,
# change, or vanish.
#
# Method: for each snapshotted file, `diff snapshot current` -- any "<"
# line means something present at the freeze is MISSING from the
# current file (removed OR modified into something else); any ">" line
# is new content, which is fine. Zero "<" lines across every file means
# append-only holds.
#
# Run under WSL bash: `wsl bash -lc "verification/reference/check_defaults.sh"`
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SNAPSHOT_DIR="$SCRIPT_DIR/defaults_snapshot"

FAIL=0
for f in "$SNAPSHOT_DIR"/*.sv; do
    name="$(basename "$f")"
    current="$REPO_ROOT/design/defaults/$name"
    if [ ! -f "$current" ]; then
        echo "VIOLATION: design/defaults/$name existed at the freeze but is now missing entirely." >&2
        FAIL=1
        continue
    fi
    removed="$(diff "$f" "$current" | grep -c '^<')"
    if [ "$removed" -ne 0 ]; then
        echo "VIOLATION: design/defaults/$name has $removed removed/modified line(s) since the freeze:" >&2
        diff "$f" "$current" | grep '^<' >&2
        FAIL=1
    fi
done

if [ "$FAIL" -eq 0 ]; then
    echo "OK: design/defaults/ is append-only relative to the P3.3 freeze snapshot."
fi
exit "$FAIL"
