#!/bin/bash
#SBATCH --job-name=xpdf_build
#SBATCH --partition=normal_q
#SBATCH --account=fuzzing
#SBATCH --constraint=amd
#SBATCH --time=00:30:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem-per-cpu=4G
#SBATCH --output=./logs/build-%j-%a.log
#SBATCH --error=./logs/build-%j-%a.log
#SBATCH --array=1-2

# Usage:
#   cluster: mkdir -p logs && sbatch build_xpdf.sh arc
#            (array task 1 -> AFL++ stable, task 2 -> original AFL)
#   local:   ./build_xpdf.sh              # builds both variants, one after the other
#            ./build_xpdf.sh stable       # only AFL++
#            ./build_xpdf.sh orig         # only original AFL
#            (optional: WRAP=/path/to/dir ./build_xpdf.sh)

set -euo pipefail

if [[ "${1:-}" = "arc" ]]; then
    # cluster
    module load GCCcore/14.3.0 LLVM/20.1.8-GCCcore-14.3.0 CMake/3.31.8-GCCcore-14.3.0

    wrap="$HOME/afl_build"
    JOBS="${SLURM_CPUS_PER_TASK:-4}"
    case "${SLURM_ARRAY_TASK_ID:-1}" in
      1) TAGS=(stable) ;;
      2) TAGS=(orig) ;;
      *) echo "Unexpected SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID}" >&2; exit 1 ;;
    esac
else
    # local linux machine
    wrap="${WRAP:-$HOME/afl_build}"
    JOBS="${JOBS:-$(nproc)}"
    case "${1:-both}" in
      stable) TAGS=(stable) ;;
      orig)   TAGS=(orig) ;;
      both)   TAGS=(stable orig) ;;
      *) echo "Usage: $0 [arc|stable|orig]" >&2; exit 1 ;;
    esac
fi

SRC="$wrap/xpdf-4.06_2"

build_variant() {
  local TAG="$1"
  local AFL_ROOT CC_WRAP CXX_WRAP

  case "$TAG" in
    stable)
      AFL_ROOT="$HOME/afl++"
      CC_WRAP="afl-clang-fast"
      CXX_WRAP="afl-clang-fast++"
      ;;
    orig)
      AFL_ROOT="$HOME/afl-orig"
      # Use the gcc wrappers: original AFL instruments via afl-as, which only
      # works when the compiler hands assembly to an external assembler (gcc).
      # afl-clang would silently produce an uninstrumented binary.
      CC_WRAP="afl-gcc"
      CXX_WRAP="afl-g++"
      ;;
  esac

  # Only this variant's AFL on PATH, so the identically named tools don't collide
  export PATH="$AFL_ROOT/bin:$PATH"
  export AFL_PATH="$AFL_ROOT/lib/afl"

  local BUILD="$SRC/build_$TAG"
  local OUT_BIN="$wrap/pdftotext.$TAG"

  echo "Building xpdf ($TAG) with $AFL_ROOT using $CC_WRAP / $CXX_WRAP ..."

  # Clean only this variant's own build dir
  rm -rf "$BUILD"
  mkdir -p "$BUILD"

  cmake -S "$SRC" -B "$BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$CC_WRAP" \
        -DCMAKE_CXX_COMPILER="$CXX_WRAP" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY

  cmake --build "$BUILD" -j"$JOBS"

  [ -x "$BUILD/xpdf/pdftotext" ] || { echo "Build produced no pdftotext" >&2; exit 1; }

  # Copy to a temp name, then rename, so a half-written file is never picked up
  cp "$BUILD/xpdf/pdftotext" "$OUT_BIN.tmp"
  mv -f "$OUT_BIN.tmp" "$OUT_BIN"

  # Sanity check 1: instrumentation present.
  # (write strings to a file: `strings | grep -q` can SIGPIPE under pipefail)
  strings "$OUT_BIN" > "$BUILD/strings.txt"
  if grep -q __afl_area_ptr "$BUILD/strings.txt"; then
    echo "OK: __afl_area_ptr found in $OUT_BIN"
  else
    echo "WARNING: __afl_area_ptr not found in $OUT_BIN" >&2
    exit 1
  fi

  # Sanity check 2: run it once on a real seed
  local SEED
  SEED="$(find "$wrap/pdf" -type f -name '*.pdf' -print -quit)"
  [ -n "$SEED" ] || { echo "No seed .pdf found in $wrap/pdf" >&2; exit 1; }

  afl-showmap -m none -o /dev/null -- "$OUT_BIN" "$SEED" /dev/null
  echo "Done: $OUT_BIN"
}

for tag in "${TAGS[@]}"; do
  # subshell: each variant gets its own PATH/AFL_PATH, and `exit` only ends that variant
  ( build_variant "$tag" )
done