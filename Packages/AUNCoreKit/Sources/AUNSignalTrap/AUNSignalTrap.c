#include "AUNSignalTrap.h"

#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { AUN_FATAL_SIGNAL_COUNT = 6 };

static const int kFatalSignals[AUN_FATAL_SIGNAL_COUNT] = {
    SIGTRAP, SIGILL, SIGABRT, SIGSEGV, SIGBUS, SIGFPE,
};

static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
// Bit 0: capture enabled. Bits 1..30: active signal-handler count (incremented/decremented by 2).
static _Atomic int g_state = 0;
static bool g_installed = false;
static char g_marker_path[4096];
static struct sigaction g_prev_actions[AUN_FATAL_SIGNAL_COUNT];

static int aun_signal_index(int sig) {
    for (int i = 0; i < AUN_FATAL_SIGNAL_COUNT; i++) {
        if (kFatalSignals[i] == sig) return i;
    }
    return -1;
}

static const char *aun_signal_name(int sig) {
    switch (sig) {
        case SIGTRAP: return "SIGTRAP";
        case SIGILL:  return "SIGILL";
        case SIGABRT: return "SIGABRT";
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGFPE:  return "SIGFPE";
        default:      return NULL;
    }
}

static size_t aun_format_marker(char *buf, size_t cap, const char *name, int64_t ms) {
    size_t pos = 0;
    while (name[pos] != '\0' && pos + 2 < cap) {
        buf[pos] = name[pos];
        pos++;
    }
    if (ms > 0 && pos + 24 < cap) {
        buf[pos++] = ' ';
        char digits[24];
        size_t n = 0;
        uint64_t v = (uint64_t)ms;
        while (v > 0 && n < sizeof(digits)) {
            digits[n++] = (char)('0' + (v % 10));
            v /= 10;
        }
        while (n > 0) {
            buf[pos++] = digits[--n];
        }
    }
    if (pos < cap) buf[pos++] = '\n';
    return pos;
}

static void aun_signal_trap_handler(int sig, siginfo_t *info, void *ucontext) {
    int prev_state = atomic_fetch_add_explicit(&g_state, 2, memory_order_acq_rel);
    if ((prev_state & 1) != 0 && g_marker_path[0] != '\0') {
        int fd = open(g_marker_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            const char *name = aun_signal_name(sig);
            if (name != NULL) {
                struct timespec ts;
                int64_t ms = 0;
                if (clock_gettime(CLOCK_REALTIME, &ts) == 0) {
                    ms = (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
                }
                char payload[48];
                size_t len = aun_format_marker(payload, sizeof(payload), name, ms);
                (void)write(fd, payload, len);
            }
            (void)close(fd);
        }
    }

    int idx = aun_signal_index(sig);
    struct sigaction restore;
    if (idx >= 0) {
        restore = g_prev_actions[idx];
    } else {
        memset(&restore, 0, sizeof(restore));
        sigemptyset(&restore.sa_mask);
        restore.sa_handler = SIG_DFL;
    }

    atomic_fetch_sub_explicit(&g_state, 2, memory_order_release);

    if ((restore.sa_flags & SA_SIGINFO) != 0) {
        if (restore.sa_sigaction != NULL && restore.sa_sigaction != aun_signal_trap_handler) {
            restore.sa_sigaction(sig, info, ucontext);
            return;
        }
    } else if (restore.sa_handler != SIG_DFL &&
               restore.sa_handler != SIG_IGN &&
               restore.sa_handler != (void (*)(int))aun_signal_trap_handler) {
        restore.sa_handler(sig);
        return;
    }

    // Prior disposition was SIG_DFL or SIG_IGN (or invalid self-chain): restore only if still ours.
    struct sigaction cur;
    if (sigaction(sig, NULL, &cur) == 0 &&
        (cur.sa_flags & SA_SIGINFO) != 0 &&
        cur.sa_sigaction == aun_signal_trap_handler) {
        if ((restore.sa_flags & SA_SIGINFO) != 0 && restore.sa_sigaction == aun_signal_trap_handler) {
            memset(&restore, 0, sizeof(restore));
            sigemptyset(&restore.sa_mask);
            restore.sa_handler = SIG_DFL;
        }
        (void)sigaction(sig, &restore, NULL);
    }
    if ((restore.sa_flags & SA_SIGINFO) == 0 && restore.sa_handler == SIG_IGN) {
        return;
    }
    sigset_t unblock;
    sigemptyset(&unblock);
    sigaddset(&unblock, sig);
    (void)sigprocmask(SIG_UNBLOCK, &unblock, NULL);
    (void)raise(sig);
}

static void aun_signal_trap_disable_locked(void) {
    atomic_fetch_and_explicit(&g_state, ~1, memory_order_acq_rel);
    if (g_installed) {
        for (int i = 0; i < AUN_FATAL_SIGNAL_COUNT; i++) {
            struct sigaction cur;
            if (sigaction(kFatalSignals[i], NULL, &cur) == 0 &&
                (cur.sa_flags & SA_SIGINFO) != 0 &&
                cur.sa_sigaction == aun_signal_trap_handler) {
                (void)sigaction(kFatalSignals[i], &g_prev_actions[i], NULL);
            }
        }
        g_installed = false;
    }
    while ((atomic_load_explicit(&g_state, memory_order_acquire) & ~1) != 0) {
        sched_yield();
    }
    g_marker_path[0] = '\0';
}

void aun_signal_trap_enable(const char *marker_path) {
    pthread_mutex_lock(&g_mutex);
    if (marker_path == NULL || marker_path[0] == '\0') {
        aun_signal_trap_disable_locked();
        pthread_mutex_unlock(&g_mutex);
        return;
    }
    size_t len = strlen(marker_path);
    if (len >= sizeof(g_marker_path)) {
        aun_signal_trap_disable_locked();
        pthread_mutex_unlock(&g_mutex);
        return;
    }
    if (g_installed) {
        if (strcmp(g_marker_path, marker_path) == 0 &&
            (atomic_load_explicit(&g_state, memory_order_acquire) & 1) != 0) {
            pthread_mutex_unlock(&g_mutex);
            return;
        }
        aun_signal_trap_disable_locked();
    }
    memcpy(g_marker_path, marker_path, len + 1);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_SIGINFO;
    action.sa_sigaction = aun_signal_trap_handler;
    for (int i = 0; i < AUN_FATAL_SIGNAL_COUNT; i++) {
        (void)sigaction(kFatalSignals[i], &action, &g_prev_actions[i]);
    }
    g_installed = true;
    // Use fetch_or (never store) so any active signal handler's +2 count is preserved.
    atomic_fetch_or_explicit(&g_state, 1, memory_order_acq_rel);
    pthread_mutex_unlock(&g_mutex);
}

void aun_signal_trap_disable(void) {
    pthread_mutex_lock(&g_mutex);
    aun_signal_trap_disable_locked();
    pthread_mutex_unlock(&g_mutex);
}

bool aun_signal_trap_is_installed(void) {
    pthread_mutex_lock(&g_mutex);
    bool installed = g_installed;
    pthread_mutex_unlock(&g_mutex);
    return installed;
}
