#!/bin/bash
#SBATCH --job-name=afl_build
#SBATCH --partition=normal_q
#SBATCH --account=fuzzing
#SBATCH --constraint=amd
#SBATCH --time=03:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem-per-cpu=4G
#SBATCH --output=./logs/build-%j.log
#SBATCH --error=./logs/build-%j.log

# Usage:
#   cluster: mkdir -p logs && sbatch build_afl.sh arc
#   local:   ./build_afl.sh

set -euo pipefail

if [[ "${1:-}" = "arc" ]]; then
    # cluster
    module load GCCcore/14.3.0
    module load LLVM/20.1.8-GCCcore-14.3.0
    module load CMake/3.31.8-GCCcore-14.3.0

    JOBS=${SLURM_CPUS_PER_TASK:-8}
else
    # local linux machine: use system toolchain
    JOBS=${JOBS:-$(nproc)}
fi

if [ -z "${LLVM_CONFIG:-}" ]; then
    for c in llvm-config llvm-config-20 llvm-config-19 llvm-config-18 llvm-config-17 llvm-config-16 llvm-config-15 llvm-config-14; do
        if command -v "$c" >/dev/null 2>&1; then
            LLVM_CONFIG=$(command -v "$c")
            break
        fi
    done
fi
[ -n "${LLVM_CONFIG:-}" ] || { echo "llvm-config not found (set LLVM_CONFIG=/path/to/llvm-config)" >&2; exit 1; }
export LLVM_CONFIG
"$LLVM_CONFIG" --version        # arc: should print 20.1.8

BUILD_DIR=$HOME/afl_build
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

###############################################################################
# AFL++ (stable)  ->  $HOME/afl++
###############################################################################
if [ ! -d AFLplusplus ]; then
    git clone https://github.com/AFLplusplus/AFLplusplus
fi
cd "$BUILD_DIR/AFLplusplus"
git fetch --all --tags
git checkout stable
git pull --ff-only || true

make clean
make source-only LLVM_CONFIG="$LLVM_CONFIG" NO_NYX=1 -j"$JOBS"
make install PREFIX="$HOME/afl++"

###############################################################################
# Original AFL (lcamtuf, 2.52b)  ->  $HOME/afl-orig
# Installed to a separate prefix: it ships binaries with the same names
# (afl-fuzz, afl-gcc, afl-showmap, ...) as AFL++.
# llvm_mode is skipped: original AFL's LLVM pass doesn't build against LLVM 20.
# Use afl-gcc / afl-clang (the wrapper scripts) for instrumentation instead.
###############################################################################
cd "$BUILD_DIR"
if [ ! -d AFL ]; then
    git clone https://github.com/google/AFL.git
fi
cd "$BUILD_DIR/AFL"

make clean
export CFLAGS="-O3 -funroll-loops -Wno-error -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types -fcommon"
AFL_NO_X86=1 make -j"$JOBS"
AFL_NO_X86=1 make install PREFIX="$HOME/afl-orig"
unset CFLAGS

###############################################################################
# Sanity check
###############################################################################
echo "== AFL++ =="
"$HOME/afl++/bin/afl-fuzz" -h 2>&1 | head -n 1 || true
echo "== original AFL =="
"$HOME/afl-orig/bin/afl-fuzz" -h 2>&1 | head -n 1 || true