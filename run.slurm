#!/bin/bash
#SBATCH --job-name=afl_fuzz
#SBATCH --partition=normal_q
#SBATCH --account=fuzzing
#SBATCH --constraint=intel
#SBATCH --time=01:30:00
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

wrap="$HOME/afl_build"
PROGRAM="pdftotext"
ID="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}_${SLURM_ARRAY_TASK_ID:-0}"
FULL_ID="${PROGRAM}_${ID}"

FUZZ_SECONDS=$((1 * 3600))
tmp_input="$TMPDIR/afl_${FULL_ID}"
mkdir -p "$tmp_input"
cp -rf "$wrap/pdf/." "$tmp_input/"
SEED_DIR=$tmp_input
SUT_PATH="$wrap/$PROGRAM"
SUT_ARGS=(@@ /dev/null)

# Node-local scratch for the fuzzer (fast, but wiped when the job ends)
OUTROOT="${TMPDIR:-/tmp}/$FULL_ID"
# Persistent location for results
RESULTS_DIR="$wrap/results"

[ -d "$SEED_DIR" ] || { echo "Missing seed dir: $SEED_DIR" >&2; exit 1; }
[ -x "$SUT_PATH" ] || { echo "Missing binary: $SUT_PATH" >&2; exit 1; }
mkdir -p "$OUTROOT" "$RESULTS_DIR"

# Assumes one cpu per task
CPU=$(grep Cpus_allowed_list /proc/self/status | awk '{print $2}')

rc=0
afl-fuzz -i "$SEED_DIR" -o "$OUTROOT" -V "$FUZZ_SECONDS" \
    -t 5000 -b "$CPU" -m 1536 -- \
    "$SUT_PATH" "${SUT_ARGS[@]}" || rc=$?
echo "afl-fuzz exited with code $rc"

if [ -f "$OUTROOT/default/fuzzer_stats" ]; then
    cp "$OUTROOT/default/fuzzer_stats" "$RESULTS_DIR/fuzzer_stats_$FULL_ID"
fi

# Tar from the parent so the archive contains only "$FULL_ID/..."
tar -C "$(dirname "$OUTROOT")" -czf "$RESULTS_DIR/$FULL_ID.out.tar.gz" "$FULL_ID"