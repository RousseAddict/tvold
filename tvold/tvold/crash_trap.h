#ifndef CRASH_TRAP_H
#define CRASH_TRAP_H

// Installs fatal-signal handlers that append a signal number and a symbolicated
// backtrace to `path`, then re-raise so the process still dies normally.
//
// This exists because the jailbroken test devices produce no .ips crash logs at
// all: when the app dies inside a framework, the app's own stage breadcrumbs
// show nothing, because no line of our code is on the stack. The handler is
// written on open/write/backtrace_symbols_fd only — all async-signal-safe —
// for the same reason DebugLog is built on POSIX I/O: the crash reporter must
// never depend on the layer being investigated.
void crash_trap_install(const char *path);

// Appends one line to the same file with a bare open/write/close.
//
// DebugLog routes every write through a serial GCD queue, and logNow does so
// with queue.sync — so a stalled queue silences every evidence channel at once
// and blocks whichever thread tried to log. This primitive shares nothing with
// it: no queue, no lock, no allocation. It is the only way to tell "the app was
// killed" apart from "the app is wedged and could no longer write".
void crash_trap_note(const char *message);

// Appends a backtrace of the MAIN thread, taken from wherever it currently is.
//
// Safe to call from any other thread: it signals the main thread, and the
// handler walks the stack it interrupted. This is the only way to see inside a
// thread that has stopped reaching any of our own instrumentation — which is
// exactly the state the main thread is in once playback starts on iOS 12.
// Records the calling thread's pthread as "main" at install time, so it must be
// installed from the main thread.
void crash_trap_dump_main(void);

#endif
