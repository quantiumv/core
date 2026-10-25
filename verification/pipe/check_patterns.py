#!/usr/bin/env python3
"""check_patterns.py [SPEC.json ...] -- do the mutation patterns still match the RTL?

An `old` text that matches nothing is not an error to mutate.py, mutate_pipe.py or
mutate_lockstep.py: the mutant is reported "PATTERN NOT FOUND" and counted as a survivor, or,
worse, it was annotated away. After a rewrite of the RTL, such patterns rot silently (P5c's spec had
13 of 20 stale for months). This is the dry run: it only reads, builds nothing, and lists every
pattern of every spec (default: all of mutants/) that no longer occurs in its target file.

  unit specs   ("dut"): the pattern must occur in the dut file
  e2e/lockstep specs: the pattern must occur in design/pipe/<file>; a "from" entry is checked
                      through the unit spec it takes the mutants from

Also reports, as information, a pattern that occurs more often than its "count" replaces (the
mutant may then not be the one intended). Exit status 1 when anything is unmatched.
Run it at the end of every RTL commit.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
MUTANTS = HERE / "mutants"


def read(rel):
    with open(REPO / rel, newline="") as f:
        return f.read()


def main():
    specs = [Path(a) for a in sys.argv[1:]] or sorted(MUTANTS.glob("*.json"))
    bad = 0
    total = 0
    amb = []
    for sp in specs:
        spec = json.loads(sp.read_text())
        if "dut" in spec:
            src = read(spec["dut"])
            targets = [(i, m["name"], src, m) for i, m in enumerate(spec["mutants"])]
        else:
            targets = []
            for i, m in enumerate(spec["mutants"]):
                if "from" in m:
                    continue                      # checked through its own unit spec
                targets.append((i, m["name"], read("design/pipe/" + m["file"]), m))
        for i, name, src, m in targets:
            total += 1
            n = src.count(m["old"])
            if n == 0:
                bad += 1
                print(f"{sp.name} [{i}] {name}: PATTERN NOT FOUND")
            elif n > m.get("count", 1):
                amb.append(f"{sp.name} [{i}] {name}: matches {n} times, replaces {m.get('count', 1)}")
    for a in amb:
        print("note: " + a)
    print(f"check_patterns: {total - bad}/{total} patterns match" + ("" if not bad else f", {bad} do not"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
