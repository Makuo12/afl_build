#!/bin/bash
#SBATCH --job-name=afl_build
#SBATCH --partition=normal_q
#SBATCH --account=fuzzing
#SBATCH --constraint=intel
#SBATCH --time=00:10:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem-per-cpu=4G
#SBATCH --output=./logs/build-%j.log
#SBATCH --error=./logs/build-%j.log

set -euo pipefail

module load GCCcore/14.3.0 LLVM/20.1.8-GCCcore-14.3.0 CMake/3.31.8-GCCcore-14.3.0
wrap="$HOME/afl_build"


case $SLURM_ARRAY_TASK_ID in
      1)
      export PATH="$HOME/afl++/bin:$PATH"
      export AFL_PATH="$HOME/afl++/lib/afl"
      
      echo "Building xpdf with AFL++ instrumentation..."

      cmake -S "$wrap/xpdf-4.06_2" -B "$wrap/xpdf-4.06_2/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_COMPILER=afl-clang-fast \
            -DCMAKE_CXX_COMPILER=afl-clang-fast++ \
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
            ..

      cmake --build "$wrap/xpdf-4.06_2/build" -j"$(nproc)"

      mv "$wrap/xpdf-4.06_2/build/xpdf/pdftotext" "$wrap/pdftotext.stable"
      strings "$wrap/pdftotext.stable" | grep -m1 __afl_area_ptr
      afl-showmap -o /dev/null -- "$wrap/pdftotext.stable" some.pdf /dev/null
      ;;
      2)
      export PATH="$HOME/afl-makuo++/bin:$PATH"
      export AFL_PATH="$HOME/afl-makuo++/lib/afl"

      echo "Building xpdf with AFL++ instrumentation..."

      cmake -S "$wrap/xpdf-4.06_2" -B "$wrap/xpdf-4.06_2/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_COMPILER=afl-clang-fast \
            -DCMAKE_CXX_COMPILER=afl-clang-fast++ \
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
            ..

      cmake --build "$wrap/xpdf-4.06_2/build" -j"$(nproc)"

      mv "$wrap/xpdf-4.06_2/build/xpdf/pdftotext" "$wrap/pdftotext.makuo"
      strings "$wrap/pdftotext.makuo" | grep -m1 __afl_area_ptr
      afl-showmap -o /dev/null -- "$wrap/pdftotext.makuo" some.pdf /dev/null
      ;;
esac
