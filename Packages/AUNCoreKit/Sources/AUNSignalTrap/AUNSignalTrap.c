#include "AUNSignalTrap.h"

#include <fcntl.h>
#include <pthread.h>
#include <pthread/introspection.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

enum {
    AUN_FATAL_SIGNAL_COUNT = 6,
    AUN_TRAMPOLINE_SLOTS = 8,
    AUN_ALT_STACK_SIZE = 131072,
};

static pthread_key_t g_alt_stack_key;
static pthread_once_t g_alt_stack_key_once = PTHREAD_ONCE_INIT;
static pthread_introspection_hook_t g_prev_introspection_hook = NULL;

static void aun_alt_stack_destructor(void *mem) {
    if (mem == NULL) return;
    stack_t cur;
    if (sigaltstack(NULL, &cur) == 0 && cur.ss_sp == mem) {
        stack_t off;
        memset(&off, 0, sizeof(off));
        off.ss_flags = SS_DISABLE;
        (void)sigaltstack(&off, NULL);
    }
    (void)munmap(mem, AUN_ALT_STACK_SIZE);
}

static void aun_install_thread_alt_stack(void) {
    stack_t cur_ss;
    if (sigaltstack(NULL, &cur_ss) != 0 || (cur_ss.ss_flags & SS_DISABLE) == 0) {
        return;
    }
    void *mem = pthread_getspecific(g_alt_stack_key);
    if (mem == NULL) {
        mem = mmap(NULL, AUN_ALT_STACK_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (mem == MAP_FAILED) {
            return;
        }
        if (pthread_setspecific(g_alt_stack_key, mem) != 0) {
            (void)munmap(mem, AUN_ALT_STACK_SIZE);
            return;
        }
    }
    stack_t ss;
    memset(&ss, 0, sizeof(ss));
    ss.ss_sp = mem;
    ss.ss_size = AUN_ALT_STACK_SIZE;
    ss.ss_flags = 0;
    (void)sigaltstack(&ss, NULL);
}

static void aun_thread_introspection_hook(unsigned int event, pthread_t thread, void *addr, size_t size);

static void aun_init_alt_stack_key(void) {
    if (pthread_key_create(&g_alt_stack_key, aun_alt_stack_destructor) == 0) {
        g_prev_introspection_hook = pthread_introspection_hook_install(aun_thread_introspection_hook);
    }
}

static const int kFatalSignals[AUN_FATAL_SIGNAL_COUNT] = {
    SIGTRAP, SIGILL, SIGABRT, SIGSEGV, SIGBUS, SIGFPE,
};

static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
// -1 when disabled; otherwise the active trampoline slot (0..AUN_TRAMPOLINE_SLOTS-1).
static _Atomic int g_enabled_slot = -1;
static _Atomic int g_active_handlers = 0;
static bool g_installed = false;
static int g_installed_slot = -1;
static int g_last_slot = -1;
static bool g_hooked[AUN_FATAL_SIGNAL_COUNT];
static char g_marker_path[4096];

static void aun_thread_introspection_hook(unsigned int event, pthread_t thread, void *addr, size_t size) {
    if (g_prev_introspection_hook != NULL) {
        g_prev_introspection_hook(event, thread, addr, size);
    }
    if (event == PTHREAD_INTROSPECTION_THREAD_START &&
        atomic_load_explicit(&g_enabled_slot, memory_order_acquire) >= 0) {
        aun_install_thread_alt_stack();
    }
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

static void aun_signal_trap_dispatch(int sig, int slot) {
    atomic_fetch_add_explicit(&g_active_handlers, 1, memory_order_acq_rel);
    if (atomic_load_explicit(&g_enabled_slot, memory_order_acquire) == slot &&
        g_marker_path[0] != '\0') {
        int fd = open(g_marker_path, O_WRONLY | O_CREAT | O_TRUNC | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0) {
            struct stat st;
            const char *name = aun_signal_name(sig);
            if (name != NULL && fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) {
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
    atomic_fetch_sub_explicit(&g_active_handlers, 1, memory_order_release);

    // Installed with SA_RESETHAND only on signals whose prior disposition was SIG_DFL, so the
    // kernel has already reset the disposition to SIG_DFL. Unblock and re-raise immediately.
    sigset_t unblock;
    sigemptyset(&unblock);
    sigaddset(&unblock, sig);
    (void)sigprocmask(SIG_UNBLOCK, &unblock, NULL);
    (void)raise(sig);
}

#define AUN_DEFINE_TRAMPOLINE(N) \
    static void aun_signal_trampoline_##N(int sig) { aun_signal_trap_dispatch(sig, (N)); }

AUN_DEFINE_TRAMPOLINE(0)
AUN_DEFINE_TRAMPOLINE(1)
AUN_DEFINE_TRAMPOLINE(2)
AUN_DEFINE_TRAMPOLINE(3)
AUN_DEFINE_TRAMPOLINE(4)
AUN_DEFINE_TRAMPOLINE(5)
AUN_DEFINE_TRAMPOLINE(6)
AUN_DEFINE_TRAMPOLINE(7)

static void (*const kTrampolines[AUN_TRAMPOLINE_SLOTS])(int) = {
    aun_signal_trampoline_0,
    aun_signal_trampoline_1,
    aun_signal_trampoline_2,
    aun_signal_trampoline_3,
    aun_signal_trampoline_4,
    aun_signal_trampoline_5,
    aun_signal_trampoline_6,
    aun_signal_trampoline_7,
};

static void aun_signal_trap_disable_locked(void) {
    atomic_store_explicit(&g_enabled_slot, -1, memory_order_release);
    if (g_installed && g_installed_slot >= 0 && g_installed_slot < AUN_TRAMPOLINE_SLOTS) {
        void (*ours)(int) = kTrampolines[g_installed_slot];
        struct sigaction dfl;
        memset(&dfl, 0, sizeof(dfl));
        sigemptyset(&dfl.sa_mask);
        dfl.sa_handler = SIG_DFL;
        for (int i = 0; i < AUN_FATAL_SIGNAL_COUNT; i++) {
            if (!g_hooked[i]) continue;
            struct sigaction cur;
            if (sigaction(kFatalSignals[i], NULL, &cur) == 0 &&
                (cur.sa_flags & SA_SIGINFO) == 0 &&
                cur.sa_handler == ours) {
                (void)sigaction(kFatalSignals[i], &dfl, NULL);
            }
            g_hooked[i] = false;
        }
        g_installed = false;
        g_installed_slot = -1;
    }
    while (atomic_load_explicit(&g_active_handlers, memory_order_acquire) != 0) {
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
            atomic_load_explicit(&g_enabled_slot, memory_order_acquire) == g_installed_slot) {
            pthread_mutex_unlock(&g_mutex);
            return;
        }
        aun_signal_trap_disable_locked();
    }
    memcpy(g_marker_path, marker_path, len + 1);
    int next_slot = (g_last_slot + 1) % AUN_TRAMPOLINE_SLOTS;
    g_last_slot = next_slot;
    (void)pthread_once(&g_alt_stack_key_once, aun_init_alt_stack_key);
    aun_install_thread_alt_stack();
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESETHAND | SA_ONSTACK;
    action.sa_handler = kTrampolines[next_slot];
    bool hooked_any = false;
    for (int i = 0; i < AUN_FATAL_SIGNAL_COUNT; i++) {
        g_hooked[i] = false;
        struct sigaction cur;
        if (sigaction(kFatalSignals[i], NULL, &cur) == 0 &&
            (cur.sa_flags & SA_SIGINFO) == 0 &&
            cur.sa_handler == SIG_DFL) {
            if (sigaction(kFatalSignals[i], &action, NULL) == 0) {
                g_hooked[i] = true;
                hooked_any = true;
            }
        }
    }
    g_installed = hooked_any;
    g_installed_slot = hooked_any ? next_slot : -1;
    atomic_store_explicit(&g_enabled_slot, g_installed_slot, memory_order_release);
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
