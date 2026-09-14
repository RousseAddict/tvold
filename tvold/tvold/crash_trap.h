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

#endif
