/**
 * compat/pthread.h — MSVC 最小 pthread 兼容层（仅 mediaengine_lib.c 用）
 *
 * 桌面端 FFI 库在 Windows（MSVC）编译时无系统 pthread.h，这里用 Win32
 * 原语实现其用到的最小子集：
 *   - mutex        → CRITICAL_SECTION
 *   - cond         → CONDITION_VARIABLE（仅 signal/broadcast/wait，无 destroy 语义）
 *   - thread       → CreateThread / WaitForSingleObject（pthread_create / join）
 *   - nanosleep    → Sleep（供引擎线程 50ms 节流）
 *
 * 接入方式：仅在 MSVC 构建时为 archoera_mediaengine 目标添加本目录到
 * include 路径（见 CMakeLists.txt），源码里的 #include <pthread.h>
 * 不经改动即解析到本文件；GCC/Clang 走系统 pthread.h。
 * 非 MSVC 环境下本头直接透传系统 pthread.h，保证 include 路径误用时安全。
 */
#ifndef COMPAT_PTHREAD_H
#define COMPAT_PTHREAD_H

#if defined(_WIN32) && defined(_MSC_VER)

/* NOMINMAX：避免 windows.h 的 min/max 宏污染后续 FFmpeg 头 */
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <stdlib.h>
#include <time.h> /* struct timespec（UCRT 自 VS2013 起提供） */

typedef HANDLE pthread_t;
typedef CRITICAL_SECTION pthread_mutex_t;
typedef CONDITION_VARIABLE pthread_cond_t;

/* ── mutex ─────────────────────────────────────────────────── */
#define pthread_mutex_init(m, a) (InitializeCriticalSection((m)), 0)
#define pthread_mutex_destroy(m) (DeleteCriticalSection((m)), 0)
#define pthread_mutex_lock(m) (EnterCriticalSection((m)), 0)
#define pthread_mutex_unlock(m) (LeaveCriticalSection((m)), 0)

/* ── cond（Win32 条件变量无需显式销毁）──────────────────────── */
#define pthread_cond_init(c, a) (InitializeConditionVariable((c)), 0)
#define pthread_cond_destroy(c) (0)
#define pthread_cond_signal(c) (WakeConditionVariable((c)), 0)
#define pthread_cond_broadcast(c) (WakeAllConditionVariable((c)), 0)
#define pthread_cond_wait(c, m) \
    (SleepConditionVariableCS((c), (m), INFINITE) ? 0 : -1)

/* ── thread ────────────────────────────────────────────────── */
/* pthread_create 的线程函数签名是 void* (*)(void*)，与 Win32 的
   DWORD WINAPI (*)(LPVOID) 不同，经一次 malloc 的 trampoline 转换。 */
typedef struct {
    void *(*fn)(void *);
    void *arg;
} _compat_thread_arg;

static DWORD WINAPI _compat_thread_start(LPVOID p)
{
    _compat_thread_arg *a = (_compat_thread_arg *)p;
    a->fn(a->arg);
    free(a);
    return 0;
}

static int pthread_create(pthread_t *thread, const void *attr,
                          void *(*fn)(void *), void *arg)
{
    (void)attr;
    _compat_thread_arg *a = (_compat_thread_arg *)malloc(sizeof(*a));
    if (!a) return -1;
    a->fn = fn;
    a->arg = arg;
    HANDLE h = CreateThread(NULL, 0, _compat_thread_start, a, 0, NULL);
    if (!h) {
        free(a);
        return -1;
    }
    *thread = h;
    return 0;
}

static int pthread_join(pthread_t thread, void **retval)
{
    (void)retval;
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
    return 0;
}

/* ── nanosleep（引擎线程节流）──────────────────────────────── */
static int nanosleep(const struct timespec *req, void *rem)
{
    (void)rem;
    Sleep((DWORD)(req->tv_sec * 1000 + req->tv_nsec / 1000000));
    return 0;
}

#else /* 非 MSVC：透传系统 pthread.h（兼容目录被误用时保持安全——
           #include_next 跳过本目录，避免自包含命中守卫后整头为空） */

#include_next <pthread.h>

#endif /* _WIN32 && _MSC_VER */

#endif /* COMPAT_PTHREAD_H */
