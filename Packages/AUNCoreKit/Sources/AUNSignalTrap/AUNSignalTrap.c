#include "AUNSignalTrap.h"

#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
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
        case SIGTRAP: return "SIGTRAP\n";
        case SIGILL:  return "SIGILL\n";
        case SIGABRT: return "SIGABRT\n";
        case SIGSEGV: return "SIGSEGV\n";
        case SIGBUS:  return "SIGBUS\n";
        case SIGFPE:  return "SIGFPE\n";
        default:      return NULL;
    }
}

static void aun_signal_trap_handler(int sig) {
    int prev_state = atomic_fetch_add_explicit(&g_state, 2, memory_order_acq_rel);
    if ((prev_state & 1) != 0 && g_marker_path[0] != '\0') {
        int fd = open(g_marker_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            const char *msg = aun_signal_name(sig);
            if (msg != NULL) {
                size_t len = 0;
                while (msg[len] != '\0') len++;
                (void)write(fd, msg, len);
            }
            (void)close(fd);
        }
    }

    int idx = aun_signal_index(sig);
    struct sigaction restore;
    if (idx >= 0) {
        restore = g_prev_actions[idx];
        if ((restore.sa_flags & SA_SIGINFO) == 0 && restore.sa_handler == aun_signal_trap_handler) {
            sigemptyset(&restore.sa_mask);
            restore.sa_flags = 0;
            restore.sa_handler = SIG_DFL;
        }
    } else {
        sigemptyset(&restore.sa_mask);
        restore.sa_flags = 0;
        restore.sa_handler = SIG_DFL;
    }

    atomic_fetch_sub_explicit(&g_state, 2, memory_order_release);

    (void)sigaction(sig, &restore, NULL);
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
            (void)sigaction(kFatalSignals[i], &g_prev_actions[i], NULL);
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
    action.sa_flags = 0;
    action.sa_handler = aun_signal_trap_handler;
    for (int i = 0; i < AUN_FATAL_SIGNAL_COUNT; i++) {
        (void)sigaction(kFatalSignals[i], &action, &g_prev_actions[i]);
    }
    g_installed = true;
    atomic_store_explicit(&g_state, 1, memory_order_release);
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
