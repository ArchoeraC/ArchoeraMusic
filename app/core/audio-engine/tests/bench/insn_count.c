// Minimal perf-stat substitute: counts user-space instructions/cycles for a child
// process via perf_event_open with inherit=1 + enable_on_exec=1.
// Usage: insn_count <cmd> [args...]
//
// Why: decode-optimization.md 的主指标是 `perf stat -e instructions`，但部分开发机
// 无 perf/valgrind。只要 `/proc/sys/kernel/perf_event_paranoid <= 2`，普通用户即可用
// perf_event_open 统计**自身子进程**的用户态指令数（exclude_kernel=1）。
//   gcc -O2 -o insn_count insn_count.c
//   taskset -c <核> ./insn_count build/archoera-audio-engine <file> --engine-mode 1 \
//       --player-file /tmp/o.wav --no-limiter
// 输出 `RESULT insn=<N> cycles=<N> wall_s=<..> rc=<..>`；跨轮次抖动小，适合做
// 「指令数下降」主指标的 A/B 判据（配合 scorecard.py 的 wall/RSS/corr）。
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <linux/perf_event.h>
#include <time.h>

static long perf_event_open(struct perf_event_attr *a, pid_t pid, int cpu,
                            int grp, unsigned long flags) {
    return syscall(__NR_perf_event_open, a, pid, cpu, grp, flags);
}

static long long read_count(int fd) {
    long long v = 0;
    if (read(fd, &v, sizeof v) != sizeof v) return -1;
    return v;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s cmd [args...]\n", argv[0]); return 2; }
    struct perf_event_attr pe;
    int fd_i = -1, fd_c = -1;

    memset(&pe, 0, sizeof pe);
    pe.size = sizeof pe;
    pe.type = PERF_TYPE_HARDWARE;
    pe.config = PERF_COUNT_HW_INSTRUCTIONS;
    pe.disabled = 1;
    pe.inherit = 1;
    pe.enable_on_exec = 1;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;
    fd_i = (int)perf_event_open(&pe, 0, -1, -1, 0);
    if (fd_i < 0) { perror("perf_event_open(instr)"); fprintf(stderr, "ERR no perf\n"); return 3; }

    memset(&pe, 0, sizeof pe);
    pe.size = sizeof pe;
    pe.type = PERF_TYPE_HARDWARE;
    pe.config = PERF_COUNT_HW_CPU_CYCLES;
    pe.disabled = 1;
    pe.inherit = 1;
    pe.enable_on_exec = 1;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;
    fd_c = (int)perf_event_open(&pe, 0, -1, -1, 0);

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    pid_t pid = fork();
    if (pid == 0) {
        execvp(argv[1], &argv[1]);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double wall = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;

    long long insn = read_count(fd_i);
    long long cyc = fd_c >= 0 ? read_count(fd_c) : -1;
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    printf("RESULT insn=%lld cycles=%lld wall_s=%.6f rc=%d\n", insn, cyc, wall, code);
    return code;
}
