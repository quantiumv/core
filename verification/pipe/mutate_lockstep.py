#!/usr/bin/env python3
"""mutate_lockstep.py SPEC.json [idx,idx,...] -- pipe mutants against the pipe-vs-ref lockstep gate.

SPEC: {"counts": [8, 24, 64], "memcfg": "sram", "delay": 0, "jobs": 3, "inner_jobs": 2, "sim": "verilator",
       "profile": "--isa imac --priv msu --smc", "extra": ["--irq-mode", "2"],
       "mutants": [{"name": "...", "file": "qv_commit.sv", "old": "text", "new": "text"},
                   {"from": "p5c_unit_decode.json", "only": [2, 5]}]}
A "from" entry pulls mutants (name/old/new) out of a unit-mutation spec in this directory; the
target file is the basename of that spec's "dut". Both kinds of entry may carry their own "profile"
and "extra", which replace the spec's for that mutant (the lock bit, say, needs an M-mode body).
A "from" entry may also carry "unit_only": {"12": "why"}: a mutant the generated programs cannot reach
(they never put the core in the state it needs), covered by the unit testbench instead. It is expected to
survive here, and is reported as such. Each mutant gets a private copy of design/pipe/
and its own outdir, and runs verification/lockstep/run_lockstep.sh --mode selfproof --dut pipe
--pipe-dir on it over the random corpus with the spec's profile. KILLED = any corpus entry failed
or the build failed; SURVIVED = every entry passed. "counts" escalates: a mutant is first run
over the first count programs, and only a survivor goes on to the next count (the results of the
programs already run are cached in its outdir), so a mutant that is easy to kill costs little.
("count": N is a single count.) A mutant marked "equivalent": true is known to
change nothing observable and is expected to survive. --skip-annotated leaves out every mutant marked
equivalent or carrying a unit_only reason (they are listed as not run): each survives the full count of programs,
which is most of a run's time. With no mutants selected the baseline
(unmutated) is run, which must PASS: use "baseline" as the selector.
"""
import json, os, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HERE = os.path.dirname(os.path.abspath(__file__))


def expand(spec):
    out = []
    for m in spec["mutants"]:
        if "from" in m:
            src = json.load(open(os.path.join(HERE, "mutants", m["from"])))
            fname = os.path.basename(src["dut"])
            for i in m.get("only", range(len(src["mutants"]))):
                u = src["mutants"][i]
                e = {"name": u["name"], "file": fname, "old": u["old"], "new": u["new"],
                     "equivalent": u.get("equivalent", False)}
                for k in ("profile", "extra"):
                    if k in m:
                        e[k] = m[k]
                if str(i) in m.get("unit_only", {}):
                    e["unit_only"] = m["unit_only"][str(i)]
                out.append(e)
        else:
            out.append(m)
    return out


def run_one(args):
    i, m, spec, tmp = args
    d = os.path.join(tmp, f"m{i}")
    shutil.copytree(os.path.join(REPO, "design/pipe"), os.path.join(d, "pipe"))
    if m is not None:
        f = os.path.join(d, "pipe", m["file"])
        src = open(f, newline="").read()
        if m["old"] not in src:
            return i, "PATTERN NOT FOUND", ""
        open(f, "w", newline="").write(src.replace(m["old"], m["new"], m.get("count", 1)))
    out = os.path.join(d, "out")
    env = dict(os.environ)
    prof = (m or {}).get("profile", spec.get("profile"))
    if prof:
        env["QV_RANDOM_PROFILE"] = prof
    counts = spec.get("counts") or [spec.get("count", 30)]
    last = ""
    for n in counts:
        cmd = ["bash", os.path.join(REPO, "verification/lockstep/run_lockstep.sh"),
               "--mode", "selfproof", "--dut", "pipe", "--pipe-dir", os.path.join(d, "pipe"),
               "--corpus", spec.get("corpus", "random"), "--random-count", str(n),
               "--memcfg-b", spec.get("memcfg", "sram"), "--delay-max", str(spec.get("delay", 0)),
               "--sim", spec.get("sim", "iverilog"), "-j", str(spec.get("inner_jobs", 2)), "--outdir", out] + (m or {}).get("extra", spec.get("extra", []))
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=spec.get("timeout", 7200),
                               cwd=REPO, env=env)
        except subprocess.TimeoutExpired:
            return i, "killed", "(timeout)"
        text = r.stdout + r.stderr
        res = [l for l in text.splitlines() if "LOCKSTEP_RESULT:" in l]
        bad = [l for l in res if "LOCKSTEP_RESULT: PASS" not in l]
        if "BUILD FAILED" in text:
            return i, "killed", "(build failed)"
        if not (r.returncode == 0 and res and not bad):
            return i, "killed", f"[{n}] " + (bad[0].strip() if bad else text[-150:].strip())
        last = f"{len(res)} entries passed"
    return i, "SURVIVED", last


def main():
    skip = "--skip-annotated" in sys.argv
    argv = [a for a in sys.argv if a != "--skip-annotated"]
    spec = json.load(open(argv[1]))
    muts = expand(spec)
    sel = argv[2] if len(argv) > 2 else None
    tmp = tempfile.mkdtemp(prefix="mutl_")
    if sel == "baseline":
        _, st, info = run_one((0, None, spec, tmp))
        print(f"  baseline: {st} {info}")
        shutil.rmtree(tmp, ignore_errors=True)
        sys.exit(0 if st == "SURVIVED" else 1)
    only = set(sel.split(",")) if sel else None
    jobs = [(i, m, spec, tmp) for i, m in enumerate(muts) if only is None or str(i) in only]
    if skip:       # the annotated ones are expected to survive: running them costs the full count each
        for i, m, _, _ in jobs:
            if m.get("equivalent", False) or "unit_only" in m:
                print(f"  [{i}] {m['name']}: not run ({'unit-test only: ' + m['unit_only'] if 'unit_only' in m else 'equivalent'})", flush=True)
        jobs = [j for j in jobs if not (j[1].get("equivalent", False) or "unit_only" in j[1])]
    survived = 0
    with ThreadPoolExecutor(max_workers=spec.get("jobs", 3)) as ex:
        for i, status, info in ex.map(run_one, jobs):
            m = muts[i]
            equiv = m.get("equivalent", False) or "unit_only" in m
            if status != "killed" and not equiv:
                survived += 1
            if status != "killed" and equiv:
                status = ("unit-test only: " + m["unit_only"]) if "unit_only" in m else "equivalent (survives, as expected)"
            print(f"  [{i}] {m['name']}: {status} {info[:110]}", flush=True)
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"LOCKSTEP MUTANTS: {len(jobs) - survived}/{len(jobs)} killed")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
