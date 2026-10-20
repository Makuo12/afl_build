#!/bin/bash
#SBATCH --job-name=aflorig_fuzz
#SBATCH --partition=normal_q
#SBATCH --account=fuzzing
#SBATCH --time=25:30:00
#SBATCH --constraint=amd
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=4G
#SBATCH --output=./logs/aflorig-%A_%a.log
#SBATCH --error=./logs/aflorig-%A_%a.log
#SBATCH --array=1-5

set -euo pipefail

echo "node=$(hostname -s) cpu=$(lscpu | grep 'Model name' | sed 's/.*: *//')"

module load GCCcore/14.3.0 LLVM/20.1.8-GCCcore-14.3.0

# Only variables original AFL (2.52b) understands
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
export AFL_SKIP_CPUFREQ=1
export AFL_NO_UI=1
export AFL_NO_AFFINITY=1

wrap="$HOME/afl_build"
PROGRAM="pdftotext"
VARIANT="orig"
AFL_ROOT="$HOME/afl-orig"
STATS_SUBDIR=""             # original AFL writes directly into <out>/

TASK="${SLURM_ARRAY_TASK_ID:-1}"
ID="${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-0}}_${TASK}"
FULL_ID="${PROGRAM}_${VARIANT}_${ID}"

FUZZ_SECONDS=$((24 * 3600))

tmp_base="${TMPDIR:-/tmp}"
tmp_input="$tmp_base/afl_${FULL_ID}"      # seeds (node-local)
BIN_DIR="$tmp_base/bin_${FULL_ID}"        # private binary copy (node-local)
WORK_DIR="$tmp_base/work_${FULL_ID}"      # cwd, so ./output/... files are per-task
OUTROOT="$tmp_base/$FULL_ID"              # fuzzer output (wiped at job end)
RESULTS_DIR="$wrap/results"               # persistent results

SUT_ARGS=(@@ /dev/null)

export PATH="$AFL_ROOT/bin:$PATH"
export AFL_PATH="$AFL_ROOT/lib/afl"

mkdir -p "$tmp_input" "$BIN_DIR" "$WORK_DIR/output" "$OUTROOT" "$RESULTS_DIR"

SUT_PATH="$BIN_DIR/$PROGRAM.$VARIANT"
cp "$wrap/$PROGRAM.$VARIANT" "$SUT_PATH"
chmod +x "$SUT_PATH"
[ -x "$SUT_PATH" ] || { echo "Missing binary: $SUT_PATH" >&2; exit 1; }

cp -rf "$wrap/pdf/." "$tmp_input/"
[ -n "$(ls -A "$tmp_input")" ] || { echo "Empty seed dir: $tmp_input" >&2; exit 1; }

cd "$WORK_DIR"

echo "Task $TASK: variant=$VARIANT afl=$AFL_ROOT node=$(hostname)"
afl-fuzz -h 2>&1 | head -n 1 || true

save_results() {
  local stats="$OUTROOT${STATS_SUBDIR:+/$STATS_SUBDIR}/fuzzer_stats"
  if [ -f "$stats" ]; then
    cp "$stats" "$RESULTS_DIR/fuzzer_stats_$FULL_ID" || true
  fi
  tar -C "$(dirname "$OUTROOT")" -czf "$RESULTS_DIR/$FULL_ID.out.tar.gz" "$FULL_ID" || true
}

FUZZ_PID=""
trap '[ -n "$FUZZ_PID" ] && kill -TERM "$FUZZ_PID" 2>/dev/null || true' TERM INT

rc=0
timeout --signal=TERM --kill-after=120 "$FUZZ_SECONDS" \
  afl-fuzz -d -i "$tmp_input" -o "$OUTROOT" \
    -t 5000 -m 2048 -- \
    "$SUT_PATH" "${SUT_ARGS[@]}" &
FUZZ_PID=$!

wait "$FUZZ_PID" || rc=$?
wait "$FUZZ_PID" 2>/dev/null || true
trap - TERM INT

echo "afl-fuzz exited with code $rc (124 = reached time limit)"

save_results
