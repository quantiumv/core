#!/usr/bin/env python3
"""mutate_pipe.py SPEC.json -- end-to-end mutants of design/pipe/ against the RVFI diff gate.

SPEC: {"seeds": 30, "first": 1, "jobs": 5, "extra": ["--no-div"],
       "mutants": [{"name": "...", "file": "qv_exu_div.sv", "old": "text", "new": "text"}]}
Each mutant gets a private copy of design/pipe/ and runs verification/pipe/run_rvfi_diff.sh
--pipe-dir on it. KILLED = the gate reported any FAIL or the build failed; SURVIVED = all seeds passed.
A mutant marked "equivalent": true is known to change nothing observable, and is expected to survive.
"""
import json, os, shutil, subprocess, sys, tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
from concurrent.futures import ThreadPoolExecutor


def run_one(args):
    i, m, spec, tmp = args
    repo = spec.get("repo", REPO)
    d = os.path.join(tmp, f"m{i}")
    shutil.copytree(os.path.join(repo, "design/pipe"), os.path.join(d, "pipe"))
    f = os.path.join(d, "pipe", m["file"])
    src = open(f, newline="").read()
    if m["old"] not in src:
        return i, "PATTERN NOT FOUND", ""
    open(f, "w", newline="").write(src.replace(m["old"], m["new"], m.get("count", 1)))
    out = os.path.join(d, "out")
    cmd = ["bash", os.path.join(repo, "verification/pipe/run_rvfi_diff.sh"),
           "--seeds", str(spec.get("seeds", 30)), "--first", str(spec.get("first", 1)),
           "--pipe-dir", os.path.join(d, "pipe"), "--outdir", out] + spec.get("extra", [])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=spec.get("timeout", 3600))
    except subprocess.TimeoutExpired:
        return i, "killed", "(timeout)"
    text = r.stdout + r.stderr
    summ = [l for l in text.splitlines() if l.startswith("RVFI_DIFF_SUMMARY")]
    fails = [l for l in text.splitlines() if ": FAIL" in l or "BUILD FAILED" in l]
    if r.returncode == 0 and summ and " 0 failed" in summ[-1]:
        return i, "SURVIVED", summ[-1]
    return i, "killed", (fails[0] if fails else (summ[-1] if summ else text[-150:]))


def main():
    spec = json.load(open(sys.argv[1]))
    tmp = tempfile.mkdtemp(prefix="mutp_")
    only = set(sys.argv[2].split(",")) if len(sys.argv) > 2 else None
    jobs = [(i, m, spec, tmp) for i, m in enumerate(spec["mutants"]) if only is None or str(i) in only]
    survived = 0
    with ThreadPoolExecutor(max_workers=spec.get("jobs", 5)) as ex:
        for i, status, info in ex.map(run_one, jobs):
            m = spec["mutants"][i]
            equiv = m.get("equivalent", False)       # known to be unobservable: expected to survive
            if status != "killed" and not equiv:
                survived += 1
            if status != "killed" and equiv:
                status = "equivalent (survives, as expected)"
            print(f"  [{i}] {m['name']}: {status} {info[:100]}", flush=True)
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"E2E MUTANTS: {len(jobs) - survived}/{len(jobs)} killed")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
