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
#SBATCH --array=1-3

# Usage:
#   cluster: mkdir -p logs && sbatch build_xpdf.sh arc
#            (array task 1 -> AFL++ stable, 2 -> original AFL, 3 -> AFL++ persistent)
#   local:   ./build_xpdf.sh              # builds all variants, one after the other
#            ./build_xpdf.sh stable       # only AFL++ (fork per input)
#            ./build_xpdf.sh persist      # only AFL++ persistent mode
#            ./build_xpdf.sh orig         # only original AFL
#            (run from the dir containing xpdf-4.06_2/, pdf/, persistent_pdftotext.cc)
#
# Outputs: pdftotext.stable, pdftotext.persist, pdftotext.orig in $wrap.

set -euo pipefail

if [[ "${1:-}" = "arc" ]]; then
    # cluster
    module load GCCcore/14.3.0 LLVM/20.1.8-GCCcore-14.3.0 CMake/3.31.8-GCCcore-14.3.0

    wrap="$HOME/afl_build"
    JOBS="${SLURM_CPUS_PER_TASK:-4}"
    case "${SLURM_ARRAY_TASK_ID:-1}" in
      1) TAGS=(stable) ;;
      2) TAGS=(orig) ;;
      3) TAGS=(persist) ;;
      *) echo "Unexpected SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID}" >&2; exit 1 ;;
    esac
else
    # local linux machine
    wrap="$(pwd)"
    JOBS="${JOBS:-$(nproc)}"
    case "${1:-all}" in
      stable)  TAGS=(stable) ;;
      persist) TAGS=(persist) ;;
      orig)    TAGS=(orig) ;;
      all)     TAGS=(stable persist orig) ;;
      *) echo "Usage: $0 [arc|stable|persist|orig]" >&2; exit 1 ;;
    esac
fi

SRC="$wrap/xpdf-4.06_2"
[ -f "$SRC/CMakeLists.txt" ] || { echo "No CMakeLists.txt in $SRC" >&2; exit 1; }

# Add an optional pdftotext_persistent target to xpdf/CMakeLists.txt (once).
# It is only built when configured with -DAFL_PERSISTENT_HARNESS=ON, so the
# normal pdftotext build is unaffected. It uses pdftotext's own sources,
# libraries and settings; pdftotext's main() is compiled from a copy renamed
# to pdftotext_main, and persistent_pdftotext.cc provides main() + __AFL_LOOP.
patch_xpdf_cmake() {
  local CML="$SRC/xpdf/CMakeLists.txt"

  [ -f "$wrap/persistent_pdftotext.cc" ] || {
    echo "Missing $wrap/persistent_pdftotext.cc" >&2; exit 1; }
  cp "$wrap/persistent_pdftotext.cc" "$SRC/xpdf/persistent_pdftotext.cc"

  if grep -q ">>> AFL++ persistent pdftotext" "$CML"; then
    return                                   # already patched
  fi

  cat >> "$CML" <<'EOF'

# >>> AFL++ persistent pdftotext (added by build_xpdf.sh) >>>
# Built only with -DAFL_PERSISTENT_HARNESS=ON. Same sources, libraries and
# settings as pdftotext, except pdftotext's main() is compiled from a copy
# renamed to pdftotext_main, and persistent_pdftotext.cc provides main()
# with the __AFL_LOOP.
if(AFL_PERSISTENT_HARNESS)
  configure_file(pdftotext.cc "${CMAKE_CURRENT_BINARY_DIR}/pdftotext_pmain.cc" COPYONLY)
  get_target_property(PT_SOURCES pdftotext SOURCES)
  list(FILTER PT_SOURCES EXCLUDE REGEX "(^|/)pdftotext\\.cc$")
  add_executable(pdftotext_persistent ${PT_SOURCES}
    "${CMAKE_CURRENT_BINARY_DIR}/pdftotext_pmain.cc"
    persistent_pdftotext.cc)
  set_source_files_properties("${CMAKE_CURRENT_BINARY_DIR}/pdftotext_pmain.cc"
    PROPERTIES COMPILE_DEFINITIONS "main=pdftotext_main")
  foreach(prop INCLUDE_DIRECTORIES COMPILE_DEFINITIONS COMPILE_OPTIONS LINK_LIBRARIES LINK_OPTIONS)
    get_target_property(val pdftotext ${prop})
    if(val)
      set_property(TARGET pdftotext_persistent APPEND PROPERTY ${prop} "${val}")
    endif()
  endforeach()
endif()
# <<< AFL++ persistent pdftotext <<<
EOF
  echo "Patched $CML with the pdftotext_persistent target"
}

build_variant() {
  local TAG="$1"
  local AFL_ROOT CC_WRAP CXX_WRAP
  local CMAKE_EXTRA=() BUILD_TARGET="pdftotext" BIN_NAME="pdftotext"

  case "$TAG" in
    stable)
      AFL_ROOT="$HOME/afl++"
      CC_WRAP="afl-clang-fast"
      CXX_WRAP="afl-clang-fast++"
      ;;
    persist)
      # Same compiler as stable; __AFL_LOOP needs afl-clang-fast(++).
      AFL_ROOT="$HOME/afl++"
      CC_WRAP="afl-clang-fast"
      CXX_WRAP="afl-clang-fast++"
      patch_xpdf_cmake
      CMAKE_EXTRA=(-DAFL_PERSISTENT_HARNESS=ON)
      BUILD_TARGET="pdftotext_persistent"
      BIN_NAME="pdftotext_persistent"
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
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        "${CMAKE_EXTRA[@]}"

  cmake --build "$BUILD" -j"$JOBS" --target "$BUILD_TARGET"

  [ -x "$BUILD/xpdf/$BIN_NAME" ] || { echo "Build produced no $BIN_NAME" >&2; exit 1; }

  # Copy to a temp name, then rename, so a half-written file is never picked up
  cp "$BUILD/xpdf/$BIN_NAME" "$OUT_BIN.tmp"
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

  # Sanity check 1b: persistent marker present, otherwise afl-fuzz would
  # silently fork for every input.
  if [ "$TAG" = persist ]; then
    if grep -q "##SIG_AFL_PERSISTENT##" "$BUILD/strings.txt"; then
      echo "OK: persistent-mode marker found in $OUT_BIN"
    else
      echo "ERROR: persistent-mode marker missing in $OUT_BIN" >&2
      exit 1
    fi
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