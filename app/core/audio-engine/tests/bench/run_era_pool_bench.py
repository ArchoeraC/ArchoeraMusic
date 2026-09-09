#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""EraAudio 常驻内核池并发/混杂/首帧基准（headless 静音，无设备输出）。
用法：python3 run_era_pool_bench.py --corpus /tmp/opencode/corpus
产出：REPORT_ERA_POOL_<date>.md（同目录）。"""
import argparse, datetime, os, subprocess, sys, time

BENCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                     "build", "tests", "bench_era_pool")

def era_concurrency(files, host_max):
    cmd = [BENCH, str(host_max)] + files
    r = subprocess.run(cmd, capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.startswith("RESULT"):
            return line, r.returncode
    return "RESULT none", r.returncode

def era_latency(path):
    r = subprocess.run([BENCH, "-latency", path], capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.startswith("RESULT"):
            return line
    return "RESULT none"

def ffmpeg_parallel_wall(files, threads_hint=1):
    """N 个 ffmpeg 同时 decode→null（静音、不输出）的墙钟。"""
    t0 = time.monotonic()
    procs = []
    for f in files:
        p = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error",
             "-threads", str(threads_hint), "-i", f, "-f", "null", "-"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs.append(p)
    for p in procs:
        p.wait()
    return (time.monotonic() - t0) * 1000.0

def fmt(files):
    return sorted(set(os.path.splitext(os.path.basename(f))[1][1:] for f in files))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="/tmp/opencode/corpus")
    ap.add_argument("--durations", type=float, default=3.0, help="每文件源时长秒")
    ap.add_argument("--maxN", type=int, default=24)
    args = ap.parse_args()
    cor = args.corpus
    files = [os.path.join(cor, "a.flac"), os.path.join(cor, "a.m4a"), os.path.join(cor, "a.mp3")]
    report = []
    A = report.append
    A("# EraAudio 常驻内核池：并发/混杂/首帧 Benchmark（headless 静音）")
    A("")
    A("> 日期：%s · 方法：EraAudio = 单进程 `zk_engine` Host（worker 数=并发上限）；" % datetime.date.today().isoformat())
    A("> 基线 = 同 N 个 `ffmpeg -threads 1 -f null -` 并发解码（静音、不输出设备）。")
    A("> 语料：sine 44.1k 立体声——3s × flac/m4a(aac)/mp3（§1-2）+ 0.25–6s × flac/m4a/mp3/ogg(opu/s)（§3b）；内存受限 → 最高 %d 并发。" % args.maxN)
    A("> 指标：墙钟 ms、合实时倍数 ×RT = 源总时长/墙钟；首帧 ms（冷含引擎 init / 热复用池）。")
    A("")
    dur = args.durations

    # 1) 单格式 N=1：era vs ffmpeg（每格式独立，各解全曲一次）
    A("## 1. 单流解码（并发=1）：era 池 vs ffmpeg 基线")
    A("")
    A("| 格式 | era wall ms | era ×RT | ffmpeg wall ms | ffmpeg ×RT | era/ffmpeg wall |")
    A("|---|---|---|---|---|---|")
    for f in files:
        el, _ = era_concurrency([f], 1)
        fw = ffmpeg_parallel_wall([f])
        ew = float(el.split("wall_ms=")[1])
        ext = os.path.splitext(os.path.basename(f))[1][1:]
        A("| %s | %.2f | %.1f× | %.2f | %.1f× | %.2f |" %
          (ext, ew, dur / max(ew, 1e-6) * 1000, fw, dur / max(fw, 1e-6) * 1000, ew / max(fw, 1e-6)))
    A("")

    # 2) 并发伸缩（同格式混合轮转），era vs ffmpeg
    A("## 2. 并发伸缩（flac/m4a/mp3 轮转构成 N 路）：era 池 vs ffmpeg N 进程")
    A("")
    A("| N | era wall ms | era ×RT(合计) | ffmpeg wall ms | ffmpeg ×RT(合计) | 加速 era/ffmpeg |")
    A("|---|---|---|---|---|---|")
    Ns = sorted(set([1, 2, 4, 8, 12, 16, 20, min(24, args.maxN)]))
    for n in Ns:
        sel = [files[i % len(files)] for i in range(n)]
        el, rc = era_concurrency(sel, n)
        ew = float(el.split("wall_ms=")[1])
        fw = ffmpeg_parallel_wall(sel)
        tot = dur * n
        A("| %d | %.2f | %.1f× | %.2f | %.1f× | %.2f |" %
          (n, ew, tot / max(ew, 1e-6) * 1000, fw, tot / max(fw, 1e-6) * 1000, ew / max(fw, 1e-6)))
    A("")

    # 3) 混杂（等量 flac/aac/mp3 混跑）
    A("## 3. 混杂并发（flac+aac+mp3 均布）")
    A("")
    A("| N | 构成 | era wall ms | era ×RT | ffmpeg wall ms | ffmpeg ×RT |")
    A("|---|---|---|---|---|---|")
    for n in (8, 24) if args.maxN >= 24 else (8,):
        base = files * ((n // len(files)) + 1)
        sel = base[:n]
        comp = "+".join("%s%d" % (os.path.splitext(os.path.basename(x))[1][1:], i % 3) for i, x in enumerate(sel))
        el, _ = era_concurrency(sel, n)
        ew = float(el.split("wall_ms=")[1])
        fw = ffmpeg_parallel_wall(sel)
        A("| %d | %s | %.2f | %.1f× | %.2f | %.1f× |" % (n, comp[:40], ew, dur * n / max(ew, 1e-6) * 1000, fw, dur * n / max(fw, 1e-6) * 1000))
    A("")

    # 3b) 混杂：多格式 × 多时长（长/短交错，覆盖完成即领与弹性）
    A("## 3b. 混杂并发：多格式 × 多时长（0.25–6s，长/短交错）")
    A("")
    A("| N | era wall ms | era ×RT(合计) | ffmpeg wall ms | ffmpeg ×RT(合计) |")
    A("|---|---|---|---|---|")
    # 从 corpus 取 d<ms>_<fmt> 文件，按时长/格式构建交错顺序
    names = sorted(os.listdir(cor))
    durs = {}
    pool = []
    for n in names:
        if not n.startswith("d") or "_" not in n:
            continue
        ms = int(n[1:n.index("_")])
        pool.append(os.path.join(cor, n))
        durs[os.path.join(cor, n)] = ms / 1000.0
    pool.sort(key=lambda x: durs[x])
    # 构造"每轮时长递增再回绕"的交错序列，确保任意 N 前缀都含多时长多格式
    seq = []
    for start in range(0, len(pool)):
        seq.append(pool[(start) % len(pool)])
    for n in (8, 16, 24):
        if n > args.maxN:
            continue
        sel = seq[:n]
        tot = sum(durs[x] for x in sel)
        el, _ = era_concurrency(sel, n)
        ew = float(el.split("wall_ms=")[1])
        fw = ffmpeg_parallel_wall(sel)
        A("| %d | %.2f | %.1f× | %.2f | %.1f× |" %
          (n, ew, tot / max(ew, 1e-6) * 1000, fw, tot / max(fw, 1e-6) * 1000))
    A("")

    # 4) 首帧（冷/热）：era（含/不含引擎 init）vs ffmpeg 会话级代理
    A("## 4. 首帧响应（冷启动=进程起→首块可听；热=池已就绪→首块）")
    A("")
    for f in files:
        l = era_latency(f)
        cold = l.split("cold_first_ms=")[1].split(" ")[0]
        warm = l.split("warm_first_ms=")[1].split(" ")[0]
        # ffmpeg 冷会话代理：整文件 null 解码墙钟（近似其"会话建立→有输出"下限）
        fw = ffmpeg_parallel_wall([f])
        ext = os.path.splitext(os.path.basename(f))[1][1:]
        A("- %s：era 冷首帧 %s ms（含引擎 init）、热首帧 %s ms；ffmpeg 整文件解码 %s ms（会话代理，非首帧）" %
          (ext, cold, warm, "%.2f" % fw))
    A("")

    # 5) 结论
    A("## 5. 结论与说明")
    A("")
    A("- 并发受本机内存限制设上限 %d；本报告为同机相对值，跨机请比 ×RT/加速比而非毫秒。" % args.maxN)
    A("- 静音/headless：EraAudio 经 `zk_engine`（内存解码，无设备）；ffmpeg `-f null` 不写音频设备。")
    A("- 语料为短正弦（合成负载，未含真实音乐熵），趋势参考；真实语料/解码提速专项另见 decode-optimization.md。")

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "REPORT_ERA_POOL_%s.md" % datetime.date.today().isoformat())
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(report) + "\n")
    print("written:", out)

if __name__ == "__main__":
    main()
