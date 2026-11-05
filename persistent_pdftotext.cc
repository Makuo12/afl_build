// AFL++ persistent-mode harness for xpdf's pdftotext.
//
// Instead of fork()ing a new process for every input, one process runs many
// inputs in a loop (__AFL_LOOP). This reuses pdftotext's own main(), renamed
// to pdftotext_main at compile time, so the parsing code and its options are
// exactly the ones your normal "pdftotext.stable" runs exercise.
//
// Build (sketch, see notes below):
//   afl-clang-fast++ -O3 -c xpdf/pdftotext.cc -Dmain=pdftotext_main ...
//   afl-clang-fast++ -O3 -c persistent_pdftotext.cc
//   link both with the xpdf libraries, exactly like pdftotext
//
// Run: same command line as before, AFL++ detects persistent mode itself:
//   afl-fuzz -i in -o out -- ./pdftotext.persistent @@ /dev/null

#include <unistd.h>

// pdftotext.cc is C++, so the renamed main has C++ linkage: no extern "C".
int pdftotext_main(int argc, char *argv[]);

#ifndef __AFL_LOOP
  // Built without afl-clang-fast (e.g. for debugging): run once.
  #define __AFL_INIT() do {} while (0)
  #define __AFL_LOOP(n) (__afl_once_++ == 0)
static int __afl_once_ = 0;
#endif

int main(int argc, char *argv[]) {

  // Deferred initialization: the forkserver starts here, after the dynamic
  // linker and static constructors have run, so they aren't repeated.
  __AFL_INIT();

  // Each iteration processes one input. AFL++ writes the next test case to
  // the @@ file before every iteration, so argv stays valid and unchanged.
  // After 10000 iterations the process exits and AFL++ forks a fresh one,
  // which bounds any state or memory that leaks between iterations.
  while (__AFL_LOOP(10000)) {

    pdftotext_main(argc, argv);

  }

  return 0;

}
