#include "crash_trap.h"

#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Captured at install time: building a path inside a signal handler would mean
// allocating, which is exactly what a handler must not do.
static char g_path[1024];

// The main thread, captured at install time so another thread can signal it.
static pthread_t g_main_thread;

static const int kFatal[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGSYS };
static const int kFatalCount = (int)(sizeof(kFatal) / sizeof(kFatal[0]));

static void write_str(int fd, const char *s) {
    if (!s) return;
    size_t n = strlen(s);
    ssize_t written = 0;
    while ((size_t)written < n) {
        ssize_t w = write(fd, s + written, n - (size_t)written);
        if (w <= 0) return;
        written += w;
    }
}

// snprintf is not async-signal-safe, so integers are formatted by hand.
static void write_int(int fd, int value) {
    char buf[16];
    int i = (int)sizeof(buf);
    int negative = value < 0;
    unsigned int v = negative ? (unsigned int)(-value) : (unsigned int)value;
    buf[--i] = '\0';
    if (v == 0) {
        buf[--i] = '0';
    } else {
        while (v > 0 && i > 0) { buf[--i] = (char)('0' + (v % 10)); v /= 10; }
    }
    if (negative && i > 0) buf[--i] = '-';
    write_str(fd, &buf[i]);
}

static const char *signal_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV (bad memory access)";
        case SIGBUS:  return "SIGBUS (bad memory alignment or access)";
        case SIGILL:  return "SIGILL (illegal instruction)";
        case SIGFPE:  return "SIGFPE (arithmetic)";
        case SIGABRT: return "SIGABRT (abort — usually an uncaught ObjC exception)";
        case SIGTRAP: return "SIGTRAP (trap — Swift runtime check failure)";
        case SIGSYS:  return "SIGSYS (bad syscall)";
        default:      return "unknown";
    }
}

static void handler(int sig, siginfo_t *info, void *context) {
    (void)info;
    (void)context;

    int fd = open(g_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write_str(fd, "\n[CRASH] fatal signal ");
        write_int(fd, sig);
        write_str(fd, " — ");
        write_str(fd, signal_name(sig));
        write_str(fd, pthread_main_np() ? " — on the MAIN thread\n" : " — on a BACKGROUND thread\n");
        write_str(fd, "[CRASH] backtrace (innermost first):\n");

        void *frames[64];
        int count = backtrace(frames, 64);
        // backtrace_symbols_fd, unlike backtrace_symbols, does not malloc.
        backtrace_symbols_fd(frames, count, fd);
        write_str(fd, "[CRASH] end of backtrace\n");
        close(fd);
    }

    // Restore the default disposition and re-raise, so the process dies exactly
    // as it would have. Swallowing the signal here would leave the app wedged in
    // a state far stranger than the crash being diagnosed.
    signal(sig, SIG_DFL);
    raise(sig);
}

void crash_trap_note(const char *message) {
    if (!g_path[0] || !message) return;
    int fd = open(g_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    write_str(fd, message);
    write_str(fd, "\n");
    close(fd);
}

// SIGUSR1 is the "where are you stuck?" probe, not a fatal signal: it dumps the
// stack it interrupted and returns, leaving the thread exactly as it was. With
// SA_RESTART an interrupted syscall resumes, so a blocked main thread goes
// straight back to being blocked.
static void dump_handler(int sig, siginfo_t *info, void *context) {
    (void)sig;
    (void)info;
    (void)context;

    int fd = open(g_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    write_str(fd, "[MAIN] stack of the main thread right now, innermost first:\n");
    void *frames[64];
    int count = backtrace(frames, 64);
    backtrace_symbols_fd(frames, count, fd);
    write_str(fd, "[MAIN] end of stack\n");
    close(fd);
}

void crash_trap_dump_main(void) {
    if (!g_main_thread) return;
    pthread_kill(g_main_thread, SIGUSR1);
}

// exit() runs atexit handlers; a signal death and a SIGKILL do not. So this line
// appearing means something called exit() on us, and its absence rules that out.
static void note_exit(void) {
    crash_trap_note("[TRAP] exit() — the process is shutting down normally");
}

void crash_trap_install(const char *path) {
    if (!path) return;
    strncpy(g_path, path, sizeof(g_path) - 1);
    g_path[sizeof(g_path) - 1] = '\0';

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);

    int installed = 0;
    for (int i = 0; i < kFatalCount; i++) {
        if (sigaction(kFatal[i], &sa, NULL) == 0) installed++;
    }

    g_main_thread = pthread_self();
    struct sigaction dump;
    memset(&dump, 0, sizeof(dump));
    dump.sa_sigaction = dump_handler;
    // SA_RESTART because this probe must not perturb what it is measuring: a
    // main thread blocked in a syscall has to go back to being blocked in it.
    dump.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESTART;
    sigemptyset(&dump.sa_mask);
    sigaction(SIGUSR1, &dump, NULL);

    atexit(note_exit);

    // Proof that the trap armed, written through the handler's own file path.
    // Without this line, silence from the trap is ambiguous: it could mean no
    // signal was raised, or that the trap was never there to catch one. Round
    // three was read as the former without ever establishing the latter.
    crash_trap_note(installed == kFatalCount
                    ? "[TRAP] armed — all 7 fatal signal handlers installed"
                    : "[TRAP] armed PARTIALLY — some handlers failed to install");
}
