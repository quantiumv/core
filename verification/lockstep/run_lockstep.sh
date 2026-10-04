#!/bin/bash
# verification/lockstep/run_lockstep.sh -- P3.4 lockstep harness driver
# (pipelining track plan). Run under WSL bash:
#   wsl bash -lc "verification/lockstep/run_lockstep.sh --mode selfproof"
#
# Three modes:
#   --mode selfproof   REF-vs-REF (both sides QV_MUTANT=0), one side on
#                       flat SRAM, the other with independently perturbed
#                       bus delay (and, with --memcfg-b cache, the cache
#                       memory configuration). Every corpus entry must PASS.
#   --mode mutant       ref_core #(QV_MUTANT_B=N) vs #(0), no bus delay by
#                       default. At least one corpus entry must FAIL --
#                       the whole point is proving the comparator catches
#                       it, not that every program happens to exercise it.
#   --mode corrupt      Default (unmutated) binary, +CORRUPT_AT/FIELD
#                       against one corpus entry per field class. The
#                       comparator must fail at EXACTLY the targeted
#                       retirement, every time.
#
# Corpus (--corpus): act (verification/lockstep/act.list, ACT4 ELFs,
# tohost-terminated), fw (verification/lockstep/fw.list, firmware/
# targets, MAX_RETIRE-terminated -- see fw.list's own header for why),
# random (qvgen.py-generated, --random-count programs, tohost-
# terminated), irq (verification/lockstep/irq.list, real-interrupt-
# taking programs, MAX_RETIRE-terminated -- see irq.list's own header
# for why; needs --irq-mode 2 passed explicitly, NOT part of "all"), smc
# (verification/lockstep/smc.list, self-modifying-code programs,
# MAX_RETIRE-terminated -- needs --memcfg-b cache passed explicitly, NOT
# part of "all"), or all (default: act + fw + random).
#
# --dut pipe puts design/pipe/core_pipe.sv on side B (pipe-vs-ref; side
# A stays ref_core). Selfproof and corrupt only, and the random corpus
# switches to what core_pipe implements (--isa imc --priv m --no-div
# --smc). --pipe-dir points the build at a modified copy of design/pipe/
# (pipe mutants).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

MODE=selfproof
DUT=ref
PIPE_DIR=design/pipe
MUTANT=0
MEMCFG_B=sram
# 0: no delay injection. --delay-max N perturbs each side's bus timing;
# lockstep_tb.sv's exact stop keeps the resulting skew harmless.
DELAY_MAX=0
# 0 (disabled) is the default and matches every run before --irq-mode
# existed -- lockstep_tb.sv itself defaults +IRQ_MODE to 0 when the
# plusarg is absent, so leaving this untouched reproduces prior behavior
# exactly. run_one() below always passes +IRQ_MODE/+IRQ_SEED now; before
# this, it never passed either plusarg at all, so lockstep_irq.sv's
# injection was structurally dead through this script regardless of mode
# or corpus -- found while characterizing QV_MUTANT==5 (see ref_core.sv's
# interrupt_sample_q), which needs a real interrupt actually taken to be
# provably caught at all.
IRQ_MODE=0
IRQ_SEED=1
IRQ_LATE=0
CORPUS=all
ONLY=""
JOBS="$(nproc 2>/dev/null || echo 4)"
OUTDIR="$REPO_ROOT/verification/lockstep/.results"
FORCE=0
RANDOM_COUNT=10
RUN_SEED=1
# Sized for the corpus's own largest outlier: ACT4's U-00 (privilege
# test) needs 393,509 retirements to complete -- confirmed both
# standalone (testbench/rvfi_tracer.sv) and through this harness -- well
# above every other ACT4 entry (a few thousand at most), and about 5.6M
# cycles behind the cache at --delay-max 8 (some 15+ minutes of wall
# time). A bigger ceiling costs nothing for the other ~110 entries,
# which all terminate via tohost long before reaching it; it only
# affects how long a genuinely hung entry takes to report TIMEOUT.
MAX_CYCLES=10000000
WALL_TIMEOUT=3600

usage() {
    cat <<EOF
Usage: run_lockstep.sh --mode selfproof|mutant|corrupt [options]

  --mode MODE          selfproof (default), mutant, or corrupt
  --dut ref|pipe       side B's core (default ref; pipe = core_pipe, not with --mode mutant)
  --pipe-dir DIR       design/pipe/ replacement for --dut pipe (default design/pipe)
  --mutant N           QV_MUTANT_B value, 1-10 (--mode mutant only)
  --memcfg-b sram|cache  side B's memory config (default sram -- also applies
                        under --mode mutant, e.g. --mutant 9 needs cache)
  --delay-max N        max bus-delay wait states (default 0 = disabled)
  --irq-mode N          0=disabled (default), 1=MTIP only, 2=MTIP+MEIP+SEIP
                        (see lockstep_irq.sv) -- qvgen.py's own corpus never
                        enables mstatus.MIE, so this only matters against a
                        program that does (e.g. repro_irq_stall.s)
  --irq-seed N          seed for the injection LFSR (default 1)
  --irq-late            make each injected level visible one cycle later
                        (separates a core that samples a cycle late, e.g.
                        QV_MUTANT 5, from one that samples on time)
  --corpus WHICH        act, fw, random, irq, smc, or all (default all --
                        irq/smc are NOT part of all, since each needs a
                        non-default flag passed explicitly -- --irq-mode 2
                        for irq, --memcfg-b cache for smc; see each
                        list's own header)
  --only REGEX          only run corpus entries whose path matches REGEX
  -j N                  parallel jobs (default: nproc)
  --outdir DIR           results directory (default verification/lockstep/.results)
  --force               ignore cached per-entry results, rerun everything
  --random-count N       how many qvgen.py programs to generate for --corpus random (default 10)
  --seed N               base seed for delay/qvgen seeding (default 1)
  --timeout N             per-entry cycle budget passed as +TIMEOUT (default 10000000)
  --wall-timeout N        real seconds per entry before it's killed (default 3600)
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --dut) DUT="$2"; shift 2 ;;
        --pipe-dir) PIPE_DIR="$2"; shift 2 ;;
        --mutant) MUTANT="$2"; shift 2 ;;
        --memcfg-b) MEMCFG_B="$2"; shift 2 ;;
        --delay-max) DELAY_MAX="$2"; shift 2 ;;
        --irq-mode) IRQ_MODE="$2"; shift 2 ;;
        --irq-seed) IRQ_SEED="$2"; shift 2 ;;
        --irq-late) IRQ_LATE=1; shift ;;
        --corpus) CORPUS="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        -j) JOBS="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --random-count) RANDOM_COUNT="$2"; shift 2 ;;
        --seed) RUN_SEED="$2"; shift 2 ;;
        --timeout) MAX_CYCLES="$2"; shift 2 ;;
        --wall-timeout) WALL_TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

case "$MODE" in
    selfproof|mutant|corrupt) ;;
    *) echo "Unknown --mode: $MODE (expected selfproof, mutant or corrupt)" >&2; exit 1 ;;
esac
if [ "$MODE" == "mutant" ] && { [ "$MUTANT" -lt 1 ] || [ "$MUTANT" -gt 10 ]; }; then
    echo "ERROR: --mode mutant needs --mutant N with N in 1..10" >&2; exit 1
fi
case "$DUT" in
    ref) ;;
    pipe) [ "$MODE" == "mutant" ] && { echo "ERROR: --mode mutant mutates ref_core; use --pipe-dir for core_pipe" >&2; exit 1; } ;;
    *) echo "Unknown --dut: $DUT (expected ref or pipe)" >&2; exit 1 ;;
esac

mkdir -p "$OUTDIR"

# ---------------- build ----------------
REF_FILES="verification/reference/ref_alu.sv verification/reference/ref_decoder.sv \
verification/reference/ref_register_file.sv verification/reference/ref_csr_file.sv \
verification/reference/ref_divider.sv verification/reference/ref_c_expand.sv \
verification/reference/ref_core.sv"
SUPPORT_FILES="design/wb4_sram.sv design/wb_arbiter2.sv design/cache_complex.sv \
design/icache.sv design/dcache.sv"
LOCKSTEP_FILES="verification/lockstep/lockstep_wb_delay.sv verification/lockstep/lockstep_mmio.sv \
verification/lockstep/lockstep_mem.sv verification/lockstep/lockstep_irq.sv \
verification/lockstep/lockstep_side.sv verification/lockstep/lockstep_rec.sv \
verification/lockstep/lockstep_cmp.sv verification/lockstep/lockstep_tb.sv"
# core_pipe and the design/ leaf modules it reuses, in pipe_design_files.list
# order (decoder.sv first: qv_decode.sv uses its INSTR_CODE macro)
PIPE_FILES=""
B_PIPE=0
if [ "$DUT" == "pipe" ]; then
    B_PIPE=1
    PIPE_FILES=$(grep -E '^design/(pipe/|decoder\.sv|alu\.sv|c_expand\.sv|csr_file\.sv|register_file\.sv)' \
                     verification/regress/pipe_design_files.list | sed "s#^design/pipe/#$PIPE_DIR/#" | tr '\n' ' ')
fi

MEMCFG_B_CACHE=0
[ "$MEMCFG_B" == "cache" ] && MEMCFG_B_CACHE=1
QV_MUTANT_B=0
[ "$MODE" == "mutant" ] && QV_MUTANT_B=$MUTANT
RUN_DELAY_MAX=$DELAY_MAX
[ "$MODE" == "mutant" ] && RUN_DELAY_MAX=0   # kill matrix: isolate the mutant, no timing noise
[ "$MODE" == "corrupt" ] && RUN_DELAY_MAX=0  # corruption self-test: deterministic, no timing noise

# Everything that changes a run's outcome is in the key, so a cached result
# from a different configuration is never reused.
# --pipe-dir isn't: point --outdir somewhere else for a modified copy.
RUN_KEY="${MODE}_${DUT}_m${QV_MUTANT_B}_${MEMCFG_B}_d${RUN_DELAY_MAX}_i${IRQ_MODE}_l${IRQ_LATE}"
VVP_BIN="$OUTDIR/lockstep_${MODE}_${DUT}_m${QV_MUTANT_B}_${MEMCFG_B}_d${RUN_DELAY_MAX}.vvp"
BUILD_LOG="$OUTDIR/build_${MODE}_${DUT}_m${QV_MUTANT_B}.log"
if [ ! -e "$VVP_BIN" ] || [ "$FORCE" == "1" ]; then
    echo "=== building $VVP_BIN ==="
    iverilog -g2012 -DRISCV_FORMAL \
        -I design -I design/defaults -I verification/reference -I verification/lockstep \
        -Plockstep_tb.QV_MUTANT_B=$QV_MUTANT_B \
        -Plockstep_tb.MEMCFG_B_CACHE=$MEMCFG_B_CACHE \
        -Plockstep_tb.DELAY_MAX=$RUN_DELAY_MAX \
        -Plockstep_tb.B_PIPE=$B_PIPE \
        -o "$VVP_BIN" \
        $PIPE_FILES $REF_FILES $SUPPORT_FILES $LOCKSTEP_FILES > "$BUILD_LOG" 2>&1
    if [ $? -ne 0 ] || ! [ -e "$VVP_BIN" ]; then
        echo "BUILD FAILED -- see $BUILD_LOG" >&2
        tail -40 "$BUILD_LOG" >&2
        exit 1
    fi
fi

# ---------------- corpus enumeration ----------------
# Each corpus entry becomes one line: tag|hexfile|tohost_addr_or_empty|max_retire_or_empty
#
# Keyed by mode+mutant as well as corpus -- two concurrent invocations
# that share a --corpus but differ in --mode (or --mutant) used to
# truncate/rewrite the SAME file, racing each other into a garbled,
# duplicate/missing-line entries list (caught by an actual concurrent
# `--mode mutant` + `--mode corrupt` run against the same corpus
# producing an untrustworthy result, not by inspection).
ENTRIES_FILE="$OUTDIR/.entries_${CORPUS}_${MODE}_${DUT}_m${MUTANT}"
: > "$ENTRIES_FILE"

build_act_entries() {
    while IFS= read -r line; do
        line="${line%%#*}"; line="$(echo "$line" | xargs)"
        [ -n "$line" ] || continue
        local elf="$REPO_ROOT/$line"
        local tag; tag="act_$(basename "$line" .elf)"
        local hex="$OUTDIR/hex_${tag}.hex"
        if [ ! -e "$hex" ] || [ "$FORCE" == "1" ]; then
            riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=8 \
                -j .text.init -j .text.rvtest -j .data -j .text.rvmodel \
                "$elf" "$hex" 2>/dev/null
        fi
        local tohost
        tohost=$(riscv64-unknown-elf-nm "$elf" 2>/dev/null | awk '$3 == "tohost" { print $1 }')
        [ -n "$tohost" ] || continue
        echo "${tag}|${hex}|${tohost}|" >> "$ENTRIES_FILE"
    done < "$REPO_ROOT/verification/lockstep/act.list"
}

build_fw_entries() {
    while IFS= read -r line; do
        line="${line%%#*}"; line="$(echo "$line" | xargs)"
        [ -n "$line" ] || continue
        IFS='|' read -r target hexname max_retire <<< "$line"
        target="$(echo "$target" | xargs)"; hexname="$(echo "$hexname" | xargs)"; max_retire="$(echo "$max_retire" | xargs)"
        [ -n "$target" ] || continue
        (cd "$REPO_ROOT/firmware" && make "$target" > "$OUTDIR/fwbuild_${target}.log" 2>&1)
        local hex="$REPO_ROOT/firmware/$hexname"
        [ -e "$hex" ] || { echo "WARN: $hex missing after 'make $target', skipping" >&2; continue; }
        echo "fw_${target}|${hex}||${max_retire}" >> "$ENTRIES_FILE"
    done < "$REPO_ROOT/verification/lockstep/fw.list"
}

# what each side-B core implements
RANDOM_PROFILE="--isa imac --priv msu --sv39 --smc"
[ "$DUT" == "pipe" ] && RANDOM_PROFILE="--isa imc --priv m --no-div --smc"

build_random_entries() {
    for i in $(seq 1 "$RANDOM_COUNT"); do
        local seed=$((RUN_SEED * 10000 + i))
        local tag="random_${seed}"
        local base="$OUTDIR/rand_${DUT}_${tag}"
        if [ ! -e "${base}.hex" ] || [ "$FORCE" == "1" ]; then
            # shellcheck disable=SC2086
            python3 "$REPO_ROOT/verification/lockstep/gen/qvgen.py" \
                $RANDOM_PROFILE --len 500 --seed "$seed" \
                --dep-bias 0.3 -o "$base" --build > "$OUTDIR/gen_${DUT}_${tag}.log" 2>&1
        fi
        [ -e "${base}.elf" ] || { echo "WARN: qvgen seed $seed failed to build, skipping" >&2; continue; }
        local tohost
        tohost=$(riscv64-unknown-elf-nm "${base}.elf" 2>/dev/null | awk '$3 == "tohost" { print $1 }')
        [ -n "$tohost" ] || continue
        echo "${tag}|${base}.hex|${tohost}|" >> "$ENTRIES_FILE"
    done
}

# Builds directly via as/ld/objcopy (matching each program's own
# documented build commands, e.g. repro_irq_stall.s's header) rather
# than `make`, since these live in verification/lockstep/ itself, not
# firmware/, and link against gen/link.ld (qvgen.py's memory map), not
# firmware/link.ld -- no shared crt0.o either, each one is self-
# contained starting at its own _start.
build_irq_entries() {
    while IFS= read -r line; do
        line="${line%%#*}"; line="$(echo "$line" | xargs)"
        [ -n "$line" ] || continue
        IFS='|' read -r target max_retire <<< "$line"
        target="$(echo "$target" | xargs)"; max_retire="$(echo "$max_retire" | xargs)"
        [ -n "$target" ] || continue
        local src="$REPO_ROOT/verification/lockstep/${target}.s"
        local hex="$OUTDIR/irq_${target}.hex"
        if [ ! -e "$hex" ] || [ "$FORCE" == "1" ]; then
            riscv64-unknown-elf-as -march=rv64imac_zicsr -mabi=lp64 -mno-relax \
                "$src" -o "$OUTDIR/irq_${target}.o" > "$OUTDIR/irqbuild_${target}.log" 2>&1 && \
            riscv64-unknown-elf-ld -T "$REPO_ROOT/verification/lockstep/gen/link.ld" \
                -o "$OUTDIR/irq_${target}.elf" "$OUTDIR/irq_${target}.o" >> "$OUTDIR/irqbuild_${target}.log" 2>&1 && \
            riscv64-unknown-elf-objcopy -O verilog -j .text.entry -j .text.handlers -j .data.misc \
                --verilog-data-width=8 "$OUTDIR/irq_${target}.elf" "$hex" >> "$OUTDIR/irqbuild_${target}.log" 2>&1
        fi
        [ -e "$hex" ] || { echo "WARN: $hex missing after build -- see $OUTDIR/irqbuild_${target}.log, skipping" >&2; continue; }
        echo "irq_${target}|${hex}||${max_retire}" >> "$ENTRIES_FILE"
    done < "$REPO_ROOT/verification/lockstep/irq.list"
}

# Same build shape as build_irq_entries(), one march flag different
# (_zifencei, for fence.i) -- kept as its own function rather than a
# parameterized helper, matching this script's existing one-function-
# per-corpus-type style (build_act_entries/build_fw_entries/...).
build_smc_entries() {
    while IFS= read -r line; do
        line="${line%%#*}"; line="$(echo "$line" | xargs)"
        [ -n "$line" ] || continue
        IFS='|' read -r target max_retire <<< "$line"
        target="$(echo "$target" | xargs)"; max_retire="$(echo "$max_retire" | xargs)"
        [ -n "$target" ] || continue
        local src="$REPO_ROOT/verification/lockstep/${target}.s"
        local hex="$OUTDIR/smc_${target}.hex"
        if [ ! -e "$hex" ] || [ "$FORCE" == "1" ]; then
            riscv64-unknown-elf-as -march=rv64imac_zicsr_zifencei -mabi=lp64 -mno-relax \
                "$src" -o "$OUTDIR/smc_${target}.o" > "$OUTDIR/smcbuild_${target}.log" 2>&1 && \
            riscv64-unknown-elf-ld -T "$REPO_ROOT/verification/lockstep/gen/link.ld" \
                -o "$OUTDIR/smc_${target}.elf" "$OUTDIR/smc_${target}.o" >> "$OUTDIR/smcbuild_${target}.log" 2>&1 && \
            riscv64-unknown-elf-objcopy -O verilog -j .text.entry -j .text.handlers -j .data.misc \
                --verilog-data-width=8 "$OUTDIR/smc_${target}.elf" "$hex" >> "$OUTDIR/smcbuild_${target}.log" 2>&1
        fi
        [ -e "$hex" ] || { echo "WARN: $hex missing after build -- see $OUTDIR/smcbuild_${target}.log, skipping" >&2; continue; }
        echo "smc_${target}|${hex}||${max_retire}" >> "$ENTRIES_FILE"
    done < "$REPO_ROOT/verification/lockstep/smc.list"
}

case "$CORPUS" in
    act) build_act_entries ;;
    fw) build_fw_entries ;;
    random) build_random_entries ;;
    irq) build_irq_entries ;;
    smc) build_smc_entries ;;
    all) build_act_entries; build_fw_entries; build_random_entries ;;
    *) echo "Unknown --corpus: $CORPUS (expected act, fw, random, irq, smc, or all)" >&2; exit 1 ;;
esac

if [ -n "$ONLY" ]; then
    grep -E "$ONLY" "$ENTRIES_FILE" > "${ENTRIES_FILE}.filtered" || true
    mv "${ENTRIES_FILE}.filtered" "$ENTRIES_FILE"
fi

total=$(wc -l < "$ENTRIES_FILE" | xargs)
echo "=== $total corpus entries selected (mode=$MODE corpus=$CORPUS) ==="

# ---------------- run ----------------
run_one() {
    local tag="$1" hex="$2" tohost="$3" max_retire="$4"
    local resfile="$OUTDIR/result_${RUN_KEY}_${tag}"
    if [ -e "$resfile" ] && [ "$FORCE" != "1" ]; then
        return
    fi
    local seed_a=$((RUN_SEED * 2 + 1))
    local seed_b=$((RUN_SEED * 2 + 2))
    local args=(+HEXFILE="$hex" +TIMEOUT=$MAX_CYCLES +DLY_SEED_A=$seed_a +DLY_SEED_B=$seed_b +IRQ_MODE=$IRQ_MODE +IRQ_SEED=$IRQ_SEED +IRQ_LATE=$IRQ_LATE)
    [ -n "$tohost" ] && args+=(+TOHOST_ADDR=$tohost)
    [ -n "$max_retire" ] && args+=(+MAX_RETIRE=$max_retire)
    local out
    out=$(cd "$REPO_ROOT" && timeout $WALL_TIMEOUT vvp "$VVP_BIN" "${args[@]}" 2>&1 | grep -v "Unable to open")
    local verdict
    verdict=$(echo "$out" | grep "^LOCKSTEP_RESULT:" | head -1)
    [ -n "$verdict" ] || verdict="LOCKSTEP_RESULT: ERROR (no result line -- see log)"
    {
        echo "$verdict"
        echo "--- full output ---"
        echo "$out"
    } > "$resfile"
    echo "${tag}: ${verdict}"
}

running=0
while IFS='|' read -r tag hex tohost max_retire; do
    run_one "$tag" "$hex" "$tohost" "$max_retire" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then
        wait -n
        running=$((running - 1))
    fi
done < "$ENTRIES_FILE"
wait

# ---------------- corruption self-test (separate flow: one entry, all field codes) ----------------
if [ "$MODE" == "corrupt" ]; then
    entry_line=$(head -1 "$ENTRIES_FILE")
    IFS='|' read -r tag hex tohost max_retire <<< "$entry_line"
    if [ -z "$tag" ]; then
        echo "ERROR: --mode corrupt needs at least one corpus entry (pick a small one with --only)" >&2
        exit 1
    fi
    echo "=== corruption self-test on $tag ($hex) ==="
    # First, an uncorrupted run to learn a real retirement order to target.
    clean_out=$(cd "$REPO_ROOT" && timeout $WALL_TIMEOUT vvp "$VVP_BIN" +HEXFILE="$hex" +TIMEOUT=$MAX_CYCLES \
        $([ -n "$tohost" ] && echo +TOHOST_ADDR=$tohost) $([ -n "$max_retire" ] && echo +MAX_RETIRE=$max_retire) 2>&1 | grep -v "Unable to open")
    clean_matched=$(echo "$clean_out" | grep "^LOCKSTEP_RESULT: PASS" | grep -oE '[0-9]+ retirements' | grep -oE '[0-9]+')
    if [ -z "$clean_matched" ] || [ "$clean_matched" -lt 10 ]; then
        echo "ERROR: uncorrupted run didn't PASS with enough retirements to target -- can't run the corruption self-test" >&2
        exit 1
    fi
    target_order=$((clean_matched / 2))
    all_ok=1
    for field in 1 2 3 4 5 6 7 8; do
        out=$(cd "$REPO_ROOT" && timeout $WALL_TIMEOUT vvp "$VVP_BIN" +HEXFILE="$hex" +TIMEOUT=$MAX_CYCLES \
            $([ -n "$tohost" ] && echo +TOHOST_ADDR=$tohost) $([ -n "$max_retire" ] && echo +MAX_RETIRE=$max_retire) \
            +CORRUPT_AT=$target_order +CORRUPT_FIELD=$field 2>&1 | grep -v "Unable to open")
        fail_at=$(echo "$out" | grep "^LOCKSTEP_RESULT: FAIL" | grep -oE 'order=[0-9]+' | grep -oE '[0-9]+')
        if [ "$fail_at" == "$target_order" ]; then
            echo "field $field: OK (caught at order=$fail_at as expected)"
        else
            echo "field $field: MISMATCH (expected order=$target_order, got '$fail_at') -- $(echo "$out" | grep '^LOCKSTEP_RESULT:')"
            all_ok=0
        fi
    done
    [ "$all_ok" == "1" ] && echo "=== corruption self-test: ALL FIELD CLASSES CAUGHT AT THE TARGETED RETIREMENT ===" \
                          || { echo "=== corruption self-test: SOME FIELD CLASSES NOT CLEANLY CAUGHT ===" >&2; exit 1; }
    exit 0
fi

# ---------------- report ----------------
# Scoped to THIS run's own selected entries (ENTRIES_FILE), not a glob
# over every result file ever written for this mode/mutant combination --
# an earlier version globbed result_${MODE}_m${QV_MUTANT_B}_*, which
# silently folded in stale results left over from a previous, differently
# --only-filtered run of the same mode/mutant (caught by hand: a mutant
# run reported "of 6" while its pass+fail summed to 9, the extra 3 being
# an earlier run's leftover PASS files).
pass=0; fail=0; timeout_n=0; error=0
while IFS='|' read -r tag _hex _tohost _max_retire; do
    f="$OUTDIR/result_${RUN_KEY}_${tag}"
    [ -e "$f" ] || { error=$((error+1)); continue; }
    line=$(head -1 "$f")
    case "$line" in
        *PASS*) pass=$((pass+1)) ;;
        *FAIL*) fail=$((fail+1)) ;;
        *TIMEOUT*) timeout_n=$((timeout_n+1)) ;;
        *) error=$((error+1)) ;;
    esac
done < "$ENTRIES_FILE"
echo "=== lockstep $MODE (QV_MUTANT_B=$QV_MUTANT_B, memcfg_b=$MEMCFG_B, delay_max=$RUN_DELAY_MAX): pass=$pass fail=$fail timeout=$timeout_n error=$error (of $total) ==="

if [ "$MODE" == "selfproof" ]; then
    [ "$fail" == "0" ] && [ "$error" == "0" ] && [ "$timeout_n" == "0" ] || { echo "selfproof FAILED: expected zero fail/timeout/error" >&2; exit 1; }
elif [ "$MODE" == "mutant" ]; then
    [ "$fail" -ge "1" ] || { echo "mutant $MUTANT NOT CAUGHT by any corpus entry" >&2; exit 1; }
fi
exit 0
