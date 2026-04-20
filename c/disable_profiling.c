// Suppress LLVM's InstrProfiling runtime file-writing.
//
// The Rust standard library statically links LLVM's profiler_builtins, whose
// static constructor tries to write "default.profraw" at launch. The iOS
// sandbox denies this, causing SIGABRT.
//
// Fix: set __llvm_profile_filename to empty before the profiling runtime's
// own constructor runs. An empty filename causes the profiling file writer
// to skip output. We use constructor priority 101 (lower = earlier; the
// profiling runtime uses default priority 65535).

extern char __llvm_profile_filename[];

__attribute__((constructor(101)))
static void disable_llvm_profiling(void) {
    __llvm_profile_filename[0] = '\0';
}
