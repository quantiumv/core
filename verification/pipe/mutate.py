#!/usr/bin/env python3
"""mutate.py SPEC.json -- run a unit testbench against textual mutants of one RTL file.

SPEC: {"dut": "design/pipe/qv_exu_div.sv", "tb": "design/pipe/qv_exu_div_tb.sv",
       "files": ["design/divider.sv", ...]   # compile list; the dut file is substituted in place
       "flags": ["-g2012", "-I", "design", ...], "cwd": "design", "pass_re": "0 failed",
       "mutants": [{"name": "...", "old": "text", "new": "text", "count": 1}]}
A mutant is KILLED if the testbench fails, times out, or doesn't compile; SURVIVED if it still passes.
A mutant marked "equivalent": true is known to change nothing observable, and is expected to survive.
The unmutated file is checked first and must pass. Every `old` must occur in the dut file.
"""
import json, os, re, subprocess, sys, tempfile, shutil

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

def run(spec_path):
    spec = json.load(open(spec_path))
    repo = spec.get("repo", REPO)
    dut = spec["dut"]
    src = open(os.path.join(repo, dut), newline="").read()
    tmp = tempfile.mkdtemp(prefix="mut_")
    results = []

    def build_and_run(text, name):
        mdir = os.path.join(tmp, name)
        os.makedirs(mdir, exist_ok=True)
        mfile = os.path.join(mdir, os.path.basename(dut))
        open(mfile, "w", newline="").write(text)
        files = [mfile if f == dut else os.path.join(repo, f) for f in spec["files"]]
        vvp = os.path.join(mdir, "sim.vvp")
        cmd = ["iverilog"] + spec.get("flags", ["-g2012"]) + ["-o", vvp] + files + [os.path.join(repo, spec["tb"])]
        cwd = os.path.join(repo, spec.get("cwd", "."))
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
        if r.returncode != 0:
            return "compile-error", r.stderr[-300:]
        try:
            r = subprocess.run(["vvp", "-n", vvp] + spec.get("plusargs", []), cwd=cwd, capture_output=True, text=True,
                               timeout=spec.get("timeout", 600))
        except subprocess.TimeoutExpired:
            return "timeout", ""
        out = r.stdout
        if re.search(spec.get("pass_re", r"\b0 failed"), out) and "FAILURES PRESENT" not in out and "TIMEOUT" not in out:
            return "pass", out[-200:]
        fails = [l for l in out.splitlines() if l.startswith("FAIL") or "MISMATCH" in l]
        return "fail", (fails[0] if fails else out[-200:])

    status, info = build_and_run(src, "base")
    print(f"baseline: {status}")
    if status != "pass":
        print(info)
        sys.exit(2)
    survived = 0
    for i, m in enumerate(spec["mutants"]):
        old, new = m["old"], m["new"]
        if old not in src:
            print(f"  [{i}] {m['name']}: PATTERN NOT FOUND")
            survived += 1
            continue
        text = src.replace(old, new, m.get("count", 1))
        status, info = build_and_run(text, f"m{i}")
        killed = status != "pass"
        equiv = m.get("equivalent", False)       # known to be unobservable: expected to survive
        if not killed and not equiv:
            survived += 1
        tag = "killed" if killed else ("equivalent (survives, as expected)" if equiv else "SURVIVED")
        print(f"  [{i}] {m['name']}: {tag} ({status}{': ' + info.strip()[:90] if killed and info else ''})")
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"MUTANTS: {len(spec['mutants']) - survived}/{len(spec['mutants'])} killed")
    sys.exit(1 if survived else 0)

if __name__ == "__main__":
    run(sys.argv[1])
