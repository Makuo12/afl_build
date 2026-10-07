#!/bin/bash
#SBATCH --job-name=afl_build
#SBATCH --partition=normal_q
#SBATCH --account=fuzzing
#SBATCH --constraint=intel
#SBATCH --time=02:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem-per-cpu=4G
#SBATCH --output=./logs/build-%j.log
#SBATCH --error=./logs/build-%j.log

set -euo pipefail

module load GCCcore/14.3.0 LLVM/20.1.8-GCCcore-14.3.0 CMake/3.31.8-GCCcore-14.3.0
export PATH="$HOME/afl++/bin:$PATH"
export AFL_PATH="$HOME/afl++/lib/afl"

wrap="$HOME/afl_build"

echo "Building xpdf with AFL++ instrumentation..."
cd "$wrap/xpdf-4.06_2"
rm -rf build && mkdir build && cd build

cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=afl-clang-fast \
      -DCMAKE_CXX_COMPILER=afl-clang-fast++ \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      ..

make -j"$(nproc)"
cp ./xpdf/pdftotext "$wrap/pdftotext"

strings "$wrap/pdftotext" | grep -m1 __afl_area_ptr
afl-showmap -o /dev/null -- "$wrap/pdftotext" some.pdf /dev/null