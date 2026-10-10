#!/bin/bash
#SBATCH --job-name=afl_fuzz
#SBATCH --partition=normal_q
#SBATCH --account=fuzzing
#SBATCH --constraint=intel
#SBATCH --time=03:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=4G
#SBATCH --output=./logs/fuzz-%j.log
#SBATCH --error=./logs/fuzz-%j.log
#SBATCH --array=1-3

set -euo pipefail

module load GCCcore/14.3.0 LLVM/20.1.8-GCCcore-14.3.0

export PATH="$HOME/afl++/bin:$PATH"
export AFL_PATH="$HOME/afl++/lib/afl"
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
export AFL_SKIP_CPUFREQ=1
export AFL_NO_UI=1
export AFL_NO_FORKSRV=1  
export AFL_NO_AFFINITY=1
# ---- Custom-mutator-only configuration ----
export AFL_DISABLE_TRIM=1
export AFL_FAST_CAL=1                   # fewer calibration runs (3 instead of 4 on stable inputs)
export AFL_NO_SYNC=1                    # don't import other instances' inputs

wrap="$HOME/afl_build"
PROGRAM="pdftotext"
ID="${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-0}}_${SLURM_ARRAY_TASK_ID:-0}"
FULL_ID="${PROGRAM}_${ID}"

FUZZ_SECONDS=$((1 * 3600))

tmp_base="${TMPDIR:-/tmp}"
tmp_input="$tmp_base/afl_${FULL_ID}"
OUTROOT="$tmp_base/$FULL_ID"            # node-local fuzzer output (wiped at job end)
RESULTS_DIR="$wrap/results"             # persistent results
MUT_SRC="$wrap/afl_mutator.c"           # adjust if the source lives elsewhere
MUT_SO="$tmp_base/afl_mutator_${FULL_ID}.so"

SUT_PATH="$wrap/$PROGRAM"
SUT_ARGS=(@@ /dev/null)

mkdir -p "$tmp_input" "$OUTROOT" "$RESULTS_DIR"
cp -rf "$wrap/pdf/." "$tmp_input/"
SEED_DIR="$tmp_input"

[ -d "$SEED_DIR" ] || { echo "Missing seed dir: $SEED_DIR" >&2; exit 1; }
[ -x "$SUT_PATH" ] || { echo "Missing binary: $SUT_PATH" >&2; exit 1; }
[ -f "$MUT_SRC" ]  || { echo "Missing mutator source: $MUT_SRC" >&2; exit 1; }

# Assumes one cpu per task
CPU=$(grep Cpus_allowed_list /proc/self/status | awk '{print $2}')

# Build the mutator into a per-task path (no race between array tasks)
gcc -shared -fPIC -o "$MUT_SO" "$MUT_SRC"


# FrameShift analysis is on by default in your build. Find the disable variable
# in docs/env_variables.md (search "frameshift") and export it here, e.g.:
# export AFL_<FRAMESHIFT_DISABLE_VAR>=1

rc=0
# -d: skip AFL++'s deterministic stages, so only your mutator generates inputs
case $SLURM_ARRAY_TASK_ID in
    1)
    afl-fuzz -d -i "$SEED_DIR" -o "$OUTROOT" -V "$FUZZ_SECONDS" \
    -t 5000 -b "$CPU" -m 1536 -- \
    "$SUT_PATH" "${SUT_ARGS[@]}" || rc=$?
    ;;
    2)
    afl-fuzz -d -i "$SEED_DIR" -o "$OUTROOT" -V "$FUZZ_SECONDS" \
    -t 5000 -b "$CPU" -m 1536 -- \
    "$SUT_PATH" "${SUT_ARGS[@]}" || rc=$?
    ;;
    3)
    afl-fuzz -Z -d -i "$SEED_DIR" -o "$OUTROOT" -V "$FUZZ_SECONDS" \
    -t 5000 -b "$CPU" -m 1536 -- \
    "$SUT_PATH" "${SUT_ARGS[@]}" || rc=$?
    ;;
esac
echo "afl-fuzz exited with code $rc"

if [ -f "$OUTROOT/default/fuzzer_stats" ]; then
  cp "$OUTROOT/default/fuzzer_stats" "$RESULTS_DIR/fuzzer_stats_$FULL_ID"
fi

# Tar from the parent so the archive contains only "$FULL_ID/..."
tar -C "$(dirname "$OUTROOT")" -czf "$RESULTS_DIR/$FULL_ID.out.tar.gz" "$FULL_ID"