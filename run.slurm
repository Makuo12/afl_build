#!/bin/bash
#SBATCH --job-name=afl_fuzz
#SBATCH --partition=normal_q
#SBATCH --account=fuzzing
#SBATCH --constraint=intel
#SBATCH --time=26:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=4G
#SBATCH --output=./logs/fuzz-%A_%a.log
#SBATCH --error=./logs/fuzz-%A_%a.log
#SBATCH --array=1-10

set -euo pipefail

module load GCCcore/14.3.0 LLVM/20.1.8-GCCcore-14.3.0

export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
export AFL_SKIP_CPUFREQ=1
export AFL_NO_UI=1
export AFL_NO_AFFINITY=1
export AFL_DISABLE_TRIM=1
export AFL_FAST_CAL=1
export AFL_NO_SYNC=1

wrap="$HOME/afl_build"
PROGRAM="pdftotext"
ID="${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-0}}_${SLURM_ARRAY_TASK_ID:-0}"
FULL_ID="${PROGRAM}_${ID}"

FUZZ_SECONDS=$((24 * 3600))

tmp_base="${TMPDIR:-/tmp}"
tmp_input="$tmp_base/afl_${FULL_ID}"      # seeds (node-local)
BIN_DIR="$tmp_base/bin_${FULL_ID}"        # this task's private binary copy (node-local)
WORK_DIR="$tmp_base/work_${FULL_ID}"      # cwd, so ./output/... files are per-task
OUTROOT="$tmp_base/$FULL_ID"              # fuzzer output (wiped at job end)
RESULTS_DIR="$wrap/results"               # persistent results

SUT_ARGS=(@@ /dev/null)

# Pick toolchain and binary variant for this task
case "$SLURM_ARRAY_TASK_ID" in
  1|2|3|4|5)
    VARIANT="stable"
    AFL_ROOT="$HOME/afl++"
    ;;
  6|7|8|9|10)
    VARIANT="makuo"
    AFL_ROOT="$HOME/afl-makuo++"
    ;;
  *)
    echo "Unsupported array task ID: $SLURM_ARRAY_TASK_ID" >&2
    exit 1
    ;;
esac

export PATH="$AFL_ROOT/bin:$PATH"
export AFL_PATH="$AFL_ROOT/lib/afl"

mkdir -p "$tmp_input" "$BIN_DIR" "$WORK_DIR/output" "$OUTROOT" "$RESULTS_DIR"

# Private, node-local copy of only the binary in use (safe if it patches itself)
SUT_PATH="$BIN_DIR/$PROGRAM.$VARIANT"
cp "$wrap/$PROGRAM.$VARIANT" "$SUT_PATH"
chmod +x "$SUT_PATH"
[ -x "$SUT_PATH" ] || { echo "Missing binary: $SUT_PATH" >&2; exit 1; }

cp -rf "$wrap/pdf/." "$tmp_input/"
[ -n "$(ls -A "$tmp_input")" ] || { echo "Empty seed dir: $tmp_input" >&2; exit 1; }

cd "$WORK_DIR"

echo "Task $SLURM_ARRAY_TASK_ID: variant=$VARIANT afl=$AFL_ROOT node=$(hostname)"

save_results() {
  if [ -f "$OUTROOT/default/fuzzer_stats" ]; then
    cp "$OUTROOT/default/fuzzer_stats" "$RESULTS_DIR/fuzzer_stats_$FULL_ID" || true
  fi
  # Tar from the parent so the archive contains only "$FULL_ID/..."
  tar -C "$(dirname "$OUTROOT")" -czf "$RESULTS_DIR/$FULL_ID.out.tar.gz" "$FULL_ID" || true
}

# Run in background so a Slurm SIGTERM (timeout/cancel) still lets us save results
rc=0
afl-fuzz -d -i "$tmp_input" -o "$OUTROOT" -V "$FUZZ_SECONDS" \
  -t 5000 -m 2048 -- \
  "$SUT_PATH" "${SUT_ARGS[@]}" &
FUZZ_PID=$!

trap 'kill -TERM "$FUZZ_PID" 2>/dev/null || true' TERM INT

wait "$FUZZ_PID" || rc=$?
# a trapped signal interrupts the first wait; wait again for afl-fuzz to finish
wait "$FUZZ_PID" 2>/dev/null || true
trap - TERM INT

echo "afl-fuzz exited with code $rc"

save_results