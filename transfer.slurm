#!/bin/bash
#SBATCH --job-name=afl_transfer
#SBATCH --partition=normal_q
#SBATCH --account=fuzzing
#SBATCH --constraint=intel
#SBATCH --time=01:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem-per-cpu=4G
#SBATCH --output=./logs/transfer-%j-%a.log
#SBATCH --error=./logs/transfer-%j-%a.log
#SBATCH --array=1

set -euo pipefail

wrap="$HOME/afl_build"

cp -rf $wrap/results/. $wrap/results/../reference/afl_run_results

