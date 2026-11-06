#!/bin/bash
#SBATCH --job-name=aflpp_persist_fuzz
#SBATCH --partition=normal_q
#SBATCH --account=fuzzing
#SBATCH --time=25:30:00
#SBATCH --constraint=amd
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=4G
#SBATCH --output=./logs/aflpp_persist-%A_%a.log
#SBATCH --error=./logs/aflpp_persist-%A_%a.log
#SBATCH --array=1-5

# Stock AFL++ in persistent mode on pdftotext.persist (the __AFL_LOOP build
# from build_xpdf.sh). afl-fuzz detects persistent mode from the binary, so
# the command line is the same as for pdftotext.stable.
#
# Usage:
#   cluster: mkdir -p logs && sbatch fuzz_aflpp_persist.sh arc
#   local:   ./fuzz_aflpp_persist.sh
#            (run from the dir containing pdftotext.persist and pdf/; optional: FUZZ_SECONDS=3600 ./fuzz_aflpp_persist.sh)

set -euo pipefail

echo "node=$(hostname -s) cpu=$(lscpu | grep 'Model name' | sed 's/.*: *//')"

export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
export AFL_SKIP_CPUFREQ=1
export AFL_NO_UI=1
export AFL_NO_AFFINITY=1
export AFL_DISABLE_TRIM=1
export AFL_FAST_CAL=1
export AFL_NO_SYNC=1

PROGRAM="pdftotext"
VARIANT="persist"
AFL_ROOT="$HOME/afl++"
STATS_SUBDIR="default"

if [[ "${1:-}" = "arc" ]]; then
    # cluster
    module load GCCcore/14.3.0 LLVM/20.1.8-GCCcore-14.3.0

    wrap="$HOME/afl_build"
    TASK="${SLURM_ARRAY_TASK_ID:-1}"
    ID="${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-0}}_${TASK}"
    tmp_base="${TMPDIR:-/tmp}"
else
    # local linux machine
    unset AFL_NO_AFFINITY          # let afl-fuzz bind itself to a free core
    wrap="$(pwd)"
    TASK=1
    ID="local_$(date +%s)_$$"
    tmp_base="/tmp"
fi

FULL_ID="${PROGRAM}_${VARIANT}_${ID}"

FUZZ_SECONDS="${FUZZ_SECONDS:-$((24 * 3600))}"

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

# Without this marker afl-fuzz silently forks for every input. (grep the file
# directly: `strings | grep -q` can fail under pipefail when grep exits early.)
if ! grep -qa '##SIG_AFL_PERSISTENT##' "$SUT_PATH"; then
    echo "Not a persistent-mode binary: $SUT_PATH (rebuild with build_xpdf.sh persist)" >&2
    exit 1
fi

cp -rf "$wrap/pdf/." "$tmp_input/"
[ -n "$(ls -A "$tmp_input")" ] || { echo "Empty seed dir: $tmp_input" >&2; exit 1; }

cd "$WORK_DIR"

echo "Task $TASK: variant=$VARIANT afl=$AFL_ROOT node=$(hostname)"
afl-fuzz -h 2>&1 | head -n 1 || true

save_results() {
  local stats="$OUTROOT${STATS_SUBDIR:+/$STATS_SUBDIR}/fuzzer_stats"
  local plot="$OUTROOT${STATS_SUBDIR:+/$STATS_SUBDIR}/plot_data"
  if [ -f "$stats" ]; then
    cp "$stats" "$RESULTS_DIR/fuzzer_stats_$FULL_ID" || true
  fi
  if [ -f "$plot" ]; then
    cp "$plot" "$RESULTS_DIR/plot_data_$FULL_ID" || true
  fi
  tar -C "$(dirname "$OUTROOT")" -czf "$RESULTS_DIR/$FULL_ID.out.tar.gz" "$FULL_ID" || true
}

FUZZ_PID=""
trap '[ -n "$FUZZ_PID" ] && kill -TERM "$FUZZ_PID" 2>/dev/null || true' TERM INT

# -z: no deterministic stages (in this AFL++, -d is deprecated and ignored).
rc=0
timeout --signal=TERM --kill-after=120 "$FUZZ_SECONDS" \
  afl-fuzz -z -i "$tmp_input" -o "$OUTROOT" \
    -t 5000 -m 2048 -- \
    "$SUT_PATH" "${SUT_ARGS[@]}" &
FUZZ_PID=$!

wait "$FUZZ_PID" || rc=$?
wait "$FUZZ_PID" 2>/dev/null || true
trap - TERM INT

echo "afl-fuzz exited with code $rc (124 = reached time limit)"

save_results
