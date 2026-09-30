module load GCCcore/14.3.0
module load LLVM/20.1.8-GCCcore-14.3.0
module load CMake/3.31.8-GCCcore-14.3.0

export LLVM_CONFIG=$(which llvm-config)
llvm-config --version        # should print 20.1.8

git clone https://github.com/AFLplusplus/AFLplusplus
cd AFLplusplus
git checkout stable          # or use the default branch if stable is too old for LLVM 20

make clean
make source-only LLVM_CONFIG=$LLVM_CONFIG NO_NYX=1 -j8
make install PREFIX=$HOME/afl++

export PATH="$HOME/afl++/bin:$PATH"
afl-fuzz -h
afl-clang-fast --version
