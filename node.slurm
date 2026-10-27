#!/bin/bash
#SBATCH --job-name=afl_both
#SBATCH --partition=normal_q
#SBATCH --account=fuzzing
#SBATCH --time=00:30:00
#SBATCH --constraint=amd
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --output=./logs/afl_both-%j.log
#SBATCH --error=./logs/afl_both-%j.log

# Usage: mkdir -p logs && sbatch fuzz_both.sh
#   optional: FUZZ_SECONDS=3600 sbatch fuzz_both.sh   (short test run)

set -uo pipefail

module load GCCcore/14.3.0 LLVM/20.1.8-GCCcore-14.3.0

PROGRAM="pdftotext"
wrap="$HOME/afl_build"
RESULTS_DIR="$wrap/results"
tmp_base="${TMPDIR:-/tmp}"
FUZZ_SECONDS="${FUZZ_SECONDS:-$((30*60))}"
JOB="${SLURM_JOB_ID:-0}"

mkdir -p "$RESULTS_DIR" ./logs

echo "node=$(hostname -s) cpu=$(lscpu | grep 'Model name' | sed 's/.*: *//')"
echo "node=$(hostname -s) job=$JOB" > "$RESULTS_DIR/node_${JOB}.txt"

# run_one <variant: stable|orig> <run number 1-5> <core>
# Runs as a background subshell, so its exports and variables stay private.
run_one() {
    VARIANT="$1"; TASK="$2"; CORE="$3"

    export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
    export AFL_SKIP_CPUFREQ=1
    export AFL_NO_UI=1
    export AFL_NO_AFFINITY=1          # pinning is done by taskset below

    if [[ "$VARIANT" = "stable" ]]; then
        AFL_ROOT="$HOME/afl++"
        STATS_SUBDIR="default"
        export AFL_DISABLE_TRIM=1     # AFL++ only
        export AFL_FAST_CAL=1
        export AFL_NO_SYNC=1
    else
        AFL_ROOT="$HOME/afl-orig"     # original AFL 2.52b
        STATS_SUBDIR=""
    fi

    FULL_ID="${PROGRAM}_${VARIANT}_${JOB}_${TASK}"
    tmp_input="$tmp_base/afl_${FULL_ID}"
    BIN_DIR="$tmp_base/bin_${FULL_ID}"
    WORK_DIR="$tmp_base/work_${FULL_ID}"
    OUTROOT="$tmp_base/$FULL_ID"
    SUT_ARGS=(@@ /dev/null)

    export PATH="$AFL_ROOT/bin:$PATH"
    export AFL_PATH="$AFL_ROOT/lib/afl"

    mkdir -p "$tmp_input" "$BIN_DIR" "$WORK_DIR/output" "$OUTROOT"

    SUT_PATH="$BIN_DIR/$PROGRAM.$VARIANT"
    cp "$wrap/$PROGRAM.$VARIANT" "$SUT_PATH"
    chmod +x "$SUT_PATH"
    [ -x "$SUT_PATH" ] || { echo "Missing binary: $SUT_PATH" >&2; return 1; }

    cp -rf "$wrap/pdf/." "$tmp_input/"
    [ -n "$(ls -A "$tmp_input")" ] || { echo "Empty seed dir: $tmp_input" >&2; return 1; }

    cd "$WORK_DIR"
    echo "run=$FULL_ID variant=$VARIANT afl=$AFL_ROOT core=$CORE node=$(hostname -s)"

    FUZZ_PID=""
    trap '[ -n "$FUZZ_PID" ] && kill -TERM "$FUZZ_PID" 2>/dev/null || true' TERM INT

    rc=0
    taskset -c "$CORE" timeout --signal=TERM --kill-after=120 "$FUZZ_SECONDS" \
        afl-fuzz -d -i "$tmp_input" -o "$OUTROOT" \
            -t 5000 -m 2048 -- \
            "$SUT_PATH" "${SUT_ARGS[@]}" &
    FUZZ_PID=$!
    wait "$FUZZ_PID" || rc=$?
    wait "$FUZZ_PID" 2>/dev/null || true
    trap - TERM INT

    echo "afl-fuzz exited with code $rc (124 = reached time limit)"

    stats="$OUTROOT${STATS_SUBDIR:+/$STATS_SUBDIR}/fuzzer_stats"
    [ -f "$stats" ] && cp "$stats" "$RESULTS_DIR/fuzzer_stats_$FULL_ID" || true
    tar -C "$(dirname "$OUTROOT")" -czf "$RESULTS_DIR/$FULL_ID.out.tar.gz" "$FULL_ID" || true
}

# Launch all 10. Cores are interleaved (stable on even, orig on odd) so neither
# fuzzer gets systematically better cores. Core 0 is left free for the OS.
PIDS=()
for n in 1 2 3 4 5; do
    run_one stable "$n" $((2*n))   > "./logs/${PROGRAM}_stable_${JOB}_${n}.log" 2>&1 &
    PIDS+=($!)
    run_one orig   "$n" $((2*n+1)) > "./logs/${PROGRAM}_orig_${JOB}_${n}.log"   2>&1 &
    PIDS+=($!)
done

# If Slurm stops the job, pass the signal on so each run can save its results
trap 'kill -TERM "${PIDS[@]}" 2>/dev/null || true' TERM INT

for p in "${PIDS[@]}"; do wait "$p" || true; done
echo "All runs finished."