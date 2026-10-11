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
#SBATCH --array=1-2

module load GCCcore/14.3.0
module load LLVM/20.1.8-GCCcore-14.3.0
module load CMake/3.31.8-GCCcore-14.3.0

export LLVM_CONFIG=$(which llvm-config)
llvm-config --version        # should print 20.1.8

# git clone https://github.com/AFLplusplus/AFLplusplus

case $SLURM_ARRAY_TASK_ID in
    1)
    cd $HOME/afl_build/AFLplusplus
    git checkout stable          # or use the default branch if stable is too old for LLVM 20

    make clean
    make source-only LLVM_CONFIG=$LLVM_CONFIG NO_NYX=1 -j8
    make install PREFIX=$HOME/afl++
    ;;
    2)
    cd $HOME/afl_build/AFLplusplus
    git checkout makuo

    make clean
    make source-only LLVM_CONFIG=$LLVM_CONFIG NO_NYX=1 -j8
    make install PREFIX=$HOME/afl-makuo++
    ;;
esac
