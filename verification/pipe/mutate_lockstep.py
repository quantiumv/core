#!/usr/bin/env python3
"""mutate_lockstep.py SPEC.json [idx,idx,...] -- pipe mutants against the pipe-vs-ref lockstep gate.

SPEC: {"count": 30, "memcfg": "sram", "delay": 0, "jobs": 3, "inner_jobs": 2,
       "profile": "--isa imac --priv msu --smc", "extra": ["--irq-mode", "2"],
       "mutants": [{"name": "...", "file": "qv_commit.sv", "old": "text", "new": "text"},
                   {"from": "p5c_unit_decode.json", "only": [2, 5]}]}
A "from" entry pulls mutants (name/old/new) out of a unit-mutation spec in this directory; the
target file is the basename of that spec's "dut". Each mutant gets a private copy of design/pipe/
and its own outdir, and runs verification/lockstep/run_lockstep.sh --mode selfproof --dut pipe
--pipe-dir on it over the random corpus with the spec's profile. KILLED = any corpus entry failed
or the build failed; SURVIVED = every entry passed. A mutant marked "equivalent": true is known to
change nothing observable and is expected to survive. With no mutants selected the baseline
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
                out.append({"name": u["name"], "file": fname, "old": u["old"], "new": u["new"],
                            "equivalent": u.get("equivalent", False)})
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
    cmd = ["bash", os.path.join(REPO, "verification/lockstep/run_lockstep.sh"),
           "--mode", "selfproof", "--dut", "pipe", "--pipe-dir", os.path.join(d, "pipe"),
           "--corpus", spec.get("corpus", "random"), "--random-count", str(spec.get("count", 30)),
           "--memcfg-b", spec.get("memcfg", "sram"), "--delay-max", str(spec.get("delay", 0)),
           "-j", str(spec.get("inner_jobs", 2)), "--outdir", out] + spec.get("extra", [])
    env = dict(os.environ)
    if "profile" in spec:
        env["QV_RANDOM_PROFILE"] = spec["profile"]
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
    if r.returncode == 0 and res and not bad:
        return i, "SURVIVED", f"{len(res)} entries passed"
    return i, "killed", (bad[0].strip() if bad else text[-150:].strip())


def main():
    spec = json.load(open(sys.argv[1]))
    muts = expand(spec)
    sel = sys.argv[2] if len(sys.argv) > 2 else None
    tmp = tempfile.mkdtemp(prefix="mutl_")
    if sel == "baseline":
        _, st, info = run_one((0, None, spec, tmp))
        print(f"  baseline: {st} {info}")
        shutil.rmtree(tmp, ignore_errors=True)
        sys.exit(0 if st == "SURVIVED" else 1)
    only = set(sel.split(",")) if sel else None
    jobs = [(i, m, spec, tmp) for i, m in enumerate(muts) if only is None or str(i) in only]
    survived = 0
    with ThreadPoolExecutor(max_workers=spec.get("jobs", 3)) as ex:
        for i, status, info in ex.map(run_one, jobs):
            m = muts[i]
            equiv = m.get("equivalent", False)
            if status != "killed" and not equiv:
                survived += 1
            if status != "killed" and equiv:
                status = "equivalent (survives, as expected)"
            print(f"  [{i}] {m['name']}: {status} {info[:110]}", flush=True)
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"LOCKSTEP MUTANTS: {len(jobs) - survived}/{len(jobs)} killed")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
