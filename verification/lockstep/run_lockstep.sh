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
# --sim verilator builds the harness with Verilator instead of Icarus (about two
# orders of magnitude faster per program; the retirement counts and verdicts are
# the same -- compare a few before trusting a big run). Icarus stays the default
# and the reference: re-run a Verilator FAIL under Icarus before believing it.
# QV_LOCKSTEP_SIM=verilator makes it the default.
#
# --dbg-mode 1 adds a scripted debugger on both sides (lockstep_dbg.sv driving a real design/dm.sv: halts,
# Access Register reads and writes, Program Buffer runs, single steps, EBREAK-to-debug and triggers, with
# every observation logged and compared), see --dbg-features for the phasing. The random corpus is then
# generated with qvgen --dbg, which keeps x22/x23 for the script.
#
# --dut pipe puts the pipelined core (design/pipe/core.sv) on side B (pipe-vs-ref; side
# A stays ref_core). Selfproof and corrupt only. The default random profile
# is the same for both (--isa imac --priv msu --sv39 --smc: the body runs in S
# or U and switches between them, with TSR/TVM and privilege probes, under
# Sv39 page tables); QV_RANDOM_PROFILE overrides it for experiments (e.g. the
# M-mode body, --priv m; --pmp, --irq, --no-sv39-fetch). --pipe-dir points
# the build at a modified copy of design/pipe/ (pipe mutants).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

MODE=selfproof
DUT=ref
PIPE_DIR=design/pipe
SIM=${QV_LOCKSTEP_SIM:-iverilog}
MUTANT=0
# extra preprocessor defines ("QV_PIPE_X=0 QV_FPU_EN=1"): the P9 feature knobs, and QV_FPU_EN, which both cores read
DEFINES=""
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
IRQ_DENSITY=4
IRQ_LATE=0
# 0 (off) matches every run before the scripted debugger existed. DBG_FEAT is the lockstep_dbg.sv feature mask:
# 1 halt, 2 step, 4 access (Access Register), 8 ebreak, 16 trigger, 32 progbuf, 64 (set per program: it is
# qvgen --dbg output), 128 hold the halt request across a resume.
DBG_MODE=0
DBG_FEAT=191
DBG_DENSITY=0     # 0 = auto: 4, 8, ... 256 by program, so the halts spread over runs of any length
DBG_LATE=0
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
  --sim iverilog|verilator  the simulator the harness is built for (default iverilog)
  --dut ref|pipe       side B's core (default ref; pipe = the pipelined core, not with --mode mutant)
  --pipe-dir DIR       design/pipe/ replacement for --dut pipe (default design/pipe)
  --defines "A=1 B=0"  preprocessor defines for the build, both sides (the QV_PIPE_* feature knobs, QV_FPU_EN);
                        part of the cache key
  --mutant N           QV_MUTANT_B value, 1-18 (--mode mutant only)
  --memcfg-b sram|cache  side B's memory config (default sram -- also applies
                        under --mode mutant, e.g. --mutant 9 needs cache)
  --delay-max N        max bus-delay wait states (default 0 = disabled)
  --irq-mode N          0=disabled (default), 1=MTIP only, 2=MTIP+MEIP+SEIP
                        (see lockstep_irq.sv) -- only matters against a
                        program that enables interrupts: repro_irq_stall.s,
                        or qvgen.py programs generated with --irq (set
                        QV_RANDOM_PROFILE='... --irq' for --corpus random)
  --irq-seed N          seed for the injection LFSR (default 1)
  --irq-density N       ~N/256 chance of a new assert per retirement, per line (default 4;
                        qvgen --irq programs want 1: their handlers are long)
  --irq-late            make each injected level visible one cycle later
                        (separates a core that samples a cycle late, e.g.
                        QV_MUTANT 5, from one that samples on time)
  --dbg-mode N          0=off (default), 1=scripted debugger on both sides (lockstep_dbg.sv)
  --dbg-features MASK   which parts of the script run (default 191 = everything but the per-program bit 64):
                        1 halt, 2 step, 4 Access Register, 8 ebreak, 16 trigger, 32 Program Buffer,
                        128 hold the halt request across a resume
  --dbg-density N       halts are about 8*N retirements apart (default 0 = auto: 4, 8, ..., 256, by program)
  --dbg-late            the script's halt level is visible one cycle later
  --corpus WHICH        act, act-fd, fw, random, irq, smc, dbg, or all (default all -- act-fd is the F/D
                        ACT config's ELFs, act_fd.list, not part of all; dbg is the directed
                        straight-line program for action-0 triggers, needs --dbg-mode 1 --
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
        --defines) DEFINES="$2"; shift 2 ;;
        --sim) SIM="$2"; shift 2 ;;
        --mutant) MUTANT="$2"; shift 2 ;;
        --memcfg-b) MEMCFG_B="$2"; shift 2 ;;
        --delay-max) DELAY_MAX="$2"; shift 2 ;;
        --irq-mode) IRQ_MODE="$2"; shift 2 ;;
        --irq-seed) IRQ_SEED="$2"; shift 2 ;;
        --irq-density) IRQ_DENSITY="$2"; shift 2 ;;
        --irq-late) IRQ_LATE=1; shift ;;
        --dbg-mode) DBG_MODE="$2"; shift 2 ;;
        --dbg-features) DBG_FEAT="$2"; shift 2 ;;
        --dbg-density) DBG_DENSITY="$2"; shift 2 ;;
        --dbg-late) DBG_LATE=1; shift ;;
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
if [ "$MODE" == "mutant" ] && { [ "$MUTANT" -lt 1 ] || [ "$MUTANT" -gt 18 ]; }; then
    echo "ERROR: --mode mutant needs --mutant N with N in 1..17" >&2; exit 1
fi
case "$DUT" in
    ref) ;;
    pipe) [ "$MODE" == "mutant" ] && { echo "ERROR: --mode mutant mutates ref_core; use --pipe-dir for the pipelined core" >&2; exit 1; } ;;
    *) echo "Unknown --dut: $DUT (expected ref or pipe)" >&2; exit 1 ;;
esac

mkdir -p "$OUTDIR"

# ---------------- build ----------------
# the reference's own files, in list order (the FPU package before its users), from ref_design_files.list
REF_FILES="$(grep -E '^verification/reference/' verification/regress/ref_design_files.list | tr '\n' ' ')"
SUPPORT_FILES="design/wb4_sram.sv design/wb_arbiter2.sv design/cache_complex.sv \
design/icache.sv design/dcache.sv design/dm.sv"
LOCKSTEP_FILES="verification/lockstep/lockstep_wb_delay.sv verification/lockstep/lockstep_mmio.sv \
verification/lockstep/lockstep_mem.sv verification/lockstep/lockstep_irq.sv \
verification/lockstep/lockstep_dbg.sv verification/lockstep/lockstep_side.sv verification/lockstep/lockstep_rec.sv \
verification/lockstep/lockstep_cmp.sv verification/lockstep/lockstep_tb.sv"
# the pipelined core and the design/ leaf modules it uses, in design_files.list
# order (decoder.sv first: qv_decode.sv uses its INSTR_CODE macro)
PIPE_FILES=""
B_PIPE=0
if [ "$DUT" == "pipe" ]; then
    B_PIPE=1
    PIPE_FILES=$(grep -E '^design/(pipe/|decoder\.sv|alu\.sv|c_expand\.sv|csr_file\.sv|register_file\.sv|divider\.sv)' \
                     verification/regress/design_files.list | sed "s#^design/pipe/#$PIPE_DIR/#" | tr '\n' ' ')
fi

MEMCFG_B_CACHE=0
[ "$MEMCFG_B" == "cache" ] && MEMCFG_B_CACHE=1
DEFINE_FLAGS=""
for d in $DEFINES; do DEFINE_FLAGS="$DEFINE_FLAGS -D$d"; done
QV_MUTANT_B=0
[ "$MODE" == "mutant" ] && QV_MUTANT_B=$MUTANT
RUN_DELAY_MAX=$DELAY_MAX
[ "$MODE" == "mutant" ] && RUN_DELAY_MAX=0   # kill matrix: isolate the mutant, no timing noise
[ "$MODE" == "corrupt" ] && RUN_DELAY_MAX=0  # corruption self-test: deterministic, no timing noise

# Everything that changes a run's outcome is in the key, so a cached result
# from a different configuration is never reused. That includes the RTL and
# testbench sources themselves (SRC_HASH, which also covers a --pipe-dir
# copy), the interrupt and delay seeds, and (see result_path) the program.
# shellcheck disable=SC2086
SRC_HASH=$( (cat $PIPE_FILES $REF_FILES $SUPPORT_FILES $LOCKSTEP_FILES \
               design/defaults/*.sv verification/reference/*.svh verification/lockstep/*.svh \
               2>/dev/null; echo "defines: $DEFINES") | sha1sum | cut -c1-8)
RUN_KEY="${MODE}_${DUT}_m${QV_MUTANT_B}_${MEMCFG_B}_d${RUN_DELAY_MAX}_i${IRQ_MODE}_l${IRQ_LATE}_q${IRQ_SEED}_y${IRQ_DENSITY}_g${DBG_MODE}-${DBG_FEAT}-${DBG_DENSITY}-${DBG_LATE}_s${RUN_SEED}_${SRC_HASH}"
[ "$SIM" == "iverilog" ] || RUN_KEY="${RUN_KEY}_${SIM}"
VVP_BIN="$OUTDIR/lockstep_${MODE}_${DUT}_m${QV_MUTANT_B}_${MEMCFG_B}_d${RUN_DELAY_MAX}_${SRC_HASH}.vvp"
BUILD_LOG="$OUTDIR/build_${MODE}_${DUT}_m${QV_MUTANT_B}.log"
case "$SIM" in
    iverilog)
        if [ ! -e "$VVP_BIN" ] || [ "$FORCE" == "1" ]; then
            echo "=== building $VVP_BIN ==="
            iverilog -g2012 -DRISCV_FORMAL $DEFINE_FLAGS $([ "$B_PIPE" == "1" ] && echo -DLS_HAVE_PIPE) \
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
        SIM_CMD=(vvp "$VVP_BIN")
        ;;
    verilator)
        VL_DIR="$OUTDIR/vl_${MODE}_${DUT}_m${QV_MUTANT_B}_${MEMCFG_B}_d${RUN_DELAY_MAX}_${SRC_HASH}"
        VL_BIN="$VL_DIR/lockstep_vl"
        if [ ! -e "$VL_BIN" ] || [ "$FORCE" == "1" ]; then
            echo "=== building $VL_BIN (verilator) ==="
            rm -rf "$VL_DIR"
            # The two cores' decoders define the same macro names; Verilator (unlike Icarus) warns about the
            # redefinition, which is harmless here: each file expands its own uses while it is being read.
            verilator --binary --timing -O2 -j ${VL_JOBS:-4} -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH \
                -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-INITIALDLY -Wno-MULTIDRIVEN -Wno-REDEFMACRO \
                -DRISCV_FORMAL $DEFINE_FLAGS $([ "$B_PIPE" == "1" ] && echo -DLS_HAVE_PIPE) -Idesign -Idesign/defaults -Iverification/reference -Iverification/lockstep \
                -GQV_MUTANT_B=$QV_MUTANT_B -GMEMCFG_B_CACHE=$MEMCFG_B_CACHE -GDELAY_MAX=$RUN_DELAY_MAX -GB_PIPE=$B_PIPE \
                --top-module lockstep_tb --Mdir "$VL_DIR" -o lockstep_vl \
                $PIPE_FILES $REF_FILES $SUPPORT_FILES $LOCKSTEP_FILES > "$BUILD_LOG" 2>&1
            if [ $? -ne 0 ] || ! [ -e "$VL_BIN" ]; then
                echo "BUILD FAILED -- see $BUILD_LOG" >&2
                grep -E "^%Error" "$BUILD_LOG" | head -20 >&2
                exit 1
            fi
        fi
        SIM_CMD=("$VL_BIN")
        ;;
    *) echo "Unknown --sim: $SIM (expected iverilog or verilator)" >&2; exit 1 ;;
esac

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

build_act_entries() {   # [list file] [tag prefix]: act.list and act_ by default
    local list="${1:-act.list}" pfx="${2:-act}"
    while IFS= read -r line; do
        line="${line%%#*}"; line="$(echo "$line" | xargs)"
        [ -n "$line" ] || continue
        local elf="$REPO_ROOT/$line"
        local tag; tag="${pfx}_$(basename "$line" .elf)"
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
    done < "$REPO_ROOT/verification/lockstep/$list"
}

build_fw_entries() {
    while IFS= read -r line; do
        line="${line%%#*}"; line="$(echo "$line" | xargs)"
        [ -n "$line" ] || continue
        IFS='|' read -r target hexname max_retire <<< "$line"
        target="$(echo "$target" | xargs)"; hexname="$(echo "$hexname" | xargs)"; max_retire="$(echo "$max_retire" | xargs)"
        [ -n "$target" ] || continue
        # firmware/'s targets always rebuild, so another run's make can
        # rewrite a hex while this run loads it: build under a lock and run
        # from a private copy
        local hex="$OUTDIR/fw_${target}.hex"
        rm -f "$hex"
        (cd "$REPO_ROOT/firmware" && flock "${TMPDIR:-/tmp}/qv_lockstep_fw.lock" \
            sh -c "make '$target' > '$OUTDIR/fwbuild_${target}.log' 2>&1 && cp '$hexname' '$hex'")
        [ -e "$hex" ] || { echo "WARN: $hex missing after 'make $target', skipping" >&2; continue; }
        echo "fw_${target}|${hex}||${max_retire}" >> "$ENTRIES_FILE"
    done < "$REPO_ROOT/verification/lockstep/fw.list"
}

# what each side-B core implements: both now run Sv39 (the pipe translates data accesses and instruction fetches)
RANDOM_PROFILE="--isa imac --priv msu --sv39 --smc"
RANDOM_PROFILE="${QV_RANDOM_PROFILE:-$RANDOM_PROFILE}"   # experiments: override the profile
[ "$DBG_MODE" != "0" ] && RANDOM_PROFILE="$RANDOM_PROFILE --dbg"   # x22/x23 are the debug script's

build_random_entries() {
    # programs are regenerated whenever the generator or the profile changes
    local gen_hash
    gen_hash=$( (cat "$REPO_ROOT/verification/lockstep/gen/qvgen.py" "$REPO_ROOT/verification/lockstep/gen/link.ld"; echo "$RANDOM_PROFILE") \
                | sha1sum | cut -c1-8)
    for i in $(seq 1 "$RANDOM_COUNT"); do
        local seed=$((RUN_SEED * 10000 + i))
        local tag="random_${seed}"
        local base="$OUTDIR/rand_${DUT}_${gen_hash}_${tag}"
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

# the directed programs for the debug script's action-0 triggers (dbg.list): same build as the smc ones
build_dbg_entries() {
    while IFS= read -r line; do
        line="${line%%#*}"; line="$(echo "$line" | xargs)"
        [ -n "$line" ] || continue
        IFS='|' read -r target max_retire <<< "$line"
        target="$(echo "$target" | xargs)"; max_retire="$(echo "$max_retire" | xargs)"
        [ -n "$target" ] || continue
        local src="$REPO_ROOT/verification/lockstep/${target}.s"
        local hex="$OUTDIR/dbg_${target}.hex"
        if [ ! -e "$hex" ] || [ "$FORCE" == "1" ] || [ "$src" -nt "$hex" ]; then
            riscv64-unknown-elf-as -march=rv64imac_zicsr_zifencei -mabi=lp64 -mno-relax                 "$src" -o "$OUTDIR/dbg_${target}.o" > "$OUTDIR/dbgbuild_${target}.log" 2>&1 &&             riscv64-unknown-elf-ld -T "$REPO_ROOT/verification/lockstep/gen/link.ld"                 -o "$OUTDIR/dbg_${target}.elf" "$OUTDIR/dbg_${target}.o" >> "$OUTDIR/dbgbuild_${target}.log" 2>&1 &&             riscv64-unknown-elf-objcopy -O verilog -j .text.entry -j .text.handlers -j .data.misc                 --verilog-data-width=8 "$OUTDIR/dbg_${target}.elf" "$hex" >> "$OUTDIR/dbgbuild_${target}.log" 2>&1
        fi
        [ -e "$hex" ] || { echo "WARN: $hex missing after build -- see $OUTDIR/dbgbuild_${target}.log, skipping" >&2; continue; }
        # one run per script seed (--random-count of them): the script's seed follows the tag
        for i in $(seq 1 "$RANDOM_COUNT"); do
            echo "dbg_${target}_${i}|${hex}||${max_retire}" >> "$ENTRIES_FILE"
        done
    done < "$REPO_ROOT/verification/lockstep/dbg.list"
}

case "$CORPUS" in
    act) build_act_entries ;;
    act-fd) build_act_entries act_fd.list actfd ;;
    fw) build_fw_entries ;;
    random) build_random_entries ;;
    irq) build_irq_entries ;;
    smc) build_smc_entries ;;
    dbg) build_dbg_entries ;;
    all) build_act_entries; build_fw_entries; build_random_entries ;;
    *) echo "Unknown --corpus: $CORPUS (expected act, act-fd, fw, random, irq, smc, dbg, or all)" >&2; exit 1 ;;
esac

if [ -n "$ONLY" ]; then
    grep -E "$ONLY" "$ENTRIES_FILE" > "${ENTRIES_FILE}.filtered" || true
    mv "${ENTRIES_FILE}.filtered" "$ENTRIES_FILE"
fi

total=$(wc -l < "$ENTRIES_FILE" | xargs)
echo "=== $total corpus entries selected (mode=$MODE corpus=$CORPUS) ==="

# ---------------- run ----------------
# A verdict is only reused for the same configuration (RUN_KEY) AND the same
# program bytes: the hash of the hex image is part of the file name.
result_path() {
    echo "$OUTDIR/result_${RUN_KEY}_${1}_$(sha1sum "$2" | cut -c1-8)"
}

# the debug-script plusargs for one program (empty when the script is off). The script's seed follows the
# program, and bit 64 of the feature mask (x22/x23/x27 are the script's) is only set for qvgen --dbg output.
dbg_args() {
    local tag="$1" feat="$DBG_FEAT" seed
    [ "$DBG_MODE" == "0" ] && return
    # (random programs are qvgen --dbg output, the dbg_* directed ones keep to x27 and to straight-line code that
    # is safe to skip, which action-0 triggers need)
    case "$tag" in random_*) feat=$((feat | 64)) ;; dbg_*) feat=$((feat | 64 | 256)) ;; *) feat=$((feat & ~64)) ;; esac
    seed=$(( (RUN_SEED * 7919 + $(printf '%s' "$tag" | cksum | cut -d' ' -f1)) % 2147483646 + 1 ))
    local density="$DBG_DENSITY"
    [ "$density" == "0" ] && density=$((4 << (seed % 7)))
    echo "+DBG_MODE=$DBG_MODE +DBG_SEED=$seed +DBG_DENSITY=$density +DBG_FEAT=$feat +DBG_LATE=$DBG_LATE"
}

run_one() {
    local tag="$1" hex="$2" tohost="$3" max_retire="$4"
    local resfile
    resfile=$(result_path "$tag" "$hex")
    if [ -e "$resfile" ] && [ "$FORCE" != "1" ]; then
        return
    fi
    local seed_a=$((RUN_SEED * 2 + 1))
    local seed_b=$((RUN_SEED * 2 + 2))
    local args=(+HEXFILE="$hex" +TIMEOUT=$MAX_CYCLES +DLY_SEED_A=$seed_a +DLY_SEED_B=$seed_b +IRQ_MODE=$IRQ_MODE +IRQ_SEED=$IRQ_SEED +IRQ_DENSITY=$IRQ_DENSITY +IRQ_LATE=$IRQ_LATE)
    [ -n "$tohost" ] && args+=(+TOHOST_ADDR=$tohost)
    [ -n "$max_retire" ] && args+=(+MAX_RETIRE=$max_retire)
    # shellcheck disable=SC2207
    args+=($(dbg_args "$tag") ${QV_LOCKSTEP_EXTRA:-})   # QV_LOCKSTEP_EXTRA: more plusargs for debugging, e.g. +DBG_TRACE
    local out
    out=$(cd "$REPO_ROOT" && timeout $WALL_TIMEOUT "${SIM_CMD[@]}" "${args[@]}" 2>&1 | grep -v "Unable to open")
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
    dargs=$(dbg_args "$tag")
    clean_out=$(cd "$REPO_ROOT" && timeout $WALL_TIMEOUT "${SIM_CMD[@]}" +HEXFILE="$hex" +TIMEOUT=$MAX_CYCLES \
        $([ -n "$tohost" ] && echo +TOHOST_ADDR=$tohost) $([ -n "$max_retire" ] && echo +MAX_RETIRE=$max_retire) $dargs 2>&1 | grep -v "Unable to open")
    clean_matched=$(echo "$clean_out" | grep "^LOCKSTEP_RESULT: PASS" | grep -oE '[0-9]+ retirements' | grep -oE '[0-9]+')
    if [ -z "$clean_matched" ] || [ "$clean_matched" -lt 10 ]; then
        echo "ERROR: uncorrupted run didn't PASS with enough retirements to target -- can't run the corruption self-test" >&2
        exit 1
    fi
    target_order=$((clean_matched / 2))
    all_ok=1
    # 13: the F/D word (FS, frm, fflags: compared at every retirement); 14: an FP register's write data, which exists
    # only where an FP register is written, so only in a build with the FPU (and a corpus with FP instructions)
    fields="1 2 3 4 5 6 7 8 13"
    echo " $DEFINES " | grep -q " QV_FPU_EN=1 " && fields="$fields 14"
    for field in $fields; do
        # A field is only compared where it means something (rd data when rd != x0, the memory address of a memory
        # access, ...), so a corruption of a retirement that has none of it passes by design. Try the next
        # retirement then; a field the comparator really does not look at passes at all 16 of them. Field 14 starts
        # at order 20 instead, inside the preamble of a qvgen --isa imafdc program, which writes every FP register
        # (the middle of a program can be a long stretch with no FP write).
        caught=0; last=""
        tries=16; base=$target_order; [ "$field" == "14" ] && { tries=64; base=20; }
        for k in $(seq 0 $((tries - 1))); do
            tgt=$((base + k))
            out=$(cd "$REPO_ROOT" && timeout $WALL_TIMEOUT "${SIM_CMD[@]}" +HEXFILE="$hex" +TIMEOUT=$MAX_CYCLES \
                $([ -n "$tohost" ] && echo +TOHOST_ADDR=$tohost) $([ -n "$max_retire" ] && echo +MAX_RETIRE=$max_retire) $dargs \
                +CORRUPT_AT=$tgt +CORRUPT_FIELD=$field 2>&1 | grep -v "Unable to open")
            fail_at=$(echo "$out" | grep "^LOCKSTEP_RESULT: FAIL" | grep -oE 'order=[0-9]+' | grep -oE '[0-9]+')
            last="$(echo "$out" | grep '^LOCKSTEP_RESULT:')"
            if [ "$fail_at" == "$tgt" ]; then
                echo "field $field: OK (caught at order=$fail_at as expected)"
                caught=1
                break
            elif [ -n "$fail_at" ]; then
                echo "field $field: MISMATCH (expected order=$tgt, got '$fail_at') -- $last"
                break
            fi
        done
        if [ "$caught" != "1" ]; then
            [ -z "$fail_at" ] && echo "field $field: NOT CAUGHT at any of $tries consecutive retirements from order=$base -- $last"
            all_ok=0
        fi
    done
    # the debug-event log, when the script ran: kind / tag / payload a / payload b of one event in the middle
    clean_events=$(echo "$clean_out" | grep "^LOCKSTEP_RESULT: PASS" | grep -oE '[0-9]+ debug events' | grep -oE '[0-9]+')
    if [ "$DBG_MODE" != "0" ]; then
        if [ -z "$clean_events" ] || [ "$clean_events" -lt 4 ]; then
            echo "ERROR: --dbg-mode ${DBG_MODE}: the uncorrupted run logged only '${clean_events:-0}' debug events, nothing to corrupt" >&2
            all_ok=0
        else
            target_event=$((clean_events / 2))
            for field in 9 10 11 12; do
                out=$(cd "$REPO_ROOT" && timeout $WALL_TIMEOUT "${SIM_CMD[@]}" +HEXFILE="$hex" +TIMEOUT=$MAX_CYCLES \
                    $([ -n "$tohost" ] && echo +TOHOST_ADDR=$tohost) $([ -n "$max_retire" ] && echo +MAX_RETIRE=$max_retire) $dargs \
                    +CORRUPT_AT=$target_event +CORRUPT_FIELD=$field 2>&1 | grep -v "Unable to open")
                if echo "$out" | grep -q "debug event #${target_event} mismatch" && echo "$out" | grep -q "^LOCKSTEP_RESULT: FAIL"; then
                    echo "field $field: OK (debug event #$target_event caught)"
                else
                    echo "field $field: MISMATCH (expected a debug event #$target_event mismatch) -- $(echo "$out" | grep '^LOCKSTEP_RESULT:')"
                    all_ok=0
                fi
            done
        fi
    fi
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
    f=$(result_path "$tag" "$_hex")
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
