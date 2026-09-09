#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""资源 wrapper：在全新 python 进程中执行命令，返回该命令组的墙钟/CPU/峰值 RSS。
用法：python3 _reswrap.py ffmpeg|era [args...]
输出：WALL=ms CPU=s RSS=KB
era 分支调用 bench_era_pool；ffmpeg 分支并发 spawn 多个 ffmpeg -threads 1 -f null。"""
import os, resource, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.normpath(os.path.join(HERE, "..", "..", "build", "tests", "bench_era_pool"))

def main():
    kind = sys.argv[1]
    args = sys.argv[2:]
    t0 = time.monotonic()
    if kind == "era":
        subprocess.run([BENCH] + args, stdout=subprocess.DEVNULL)
    else:  # ffmpeg: args = 文件列表（每文件一个 ffmpeg 并发）
        ps = [subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error",
                                "-threads", "1", "-i", f, "-f", "null", "-"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
              for f in args]
        for p in ps:
            p.wait()
    wall = (time.monotonic() - t0) * 1000.0
    u = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = u.ru_utime + u.ru_stime
    print("WALL=%.3f CPU=%.4f RSS=%d" % (wall, cpu, u.ru_maxrss))

if __name__ == "__main__":
    main()
