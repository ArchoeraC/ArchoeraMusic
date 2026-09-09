#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""EraAudio 常驻内核池 · scorecard 口径扩测（真实曲目→音乐结构仿真 + 资源开销纳入评分）。

口径：
  - 语料：可复现的「音乐结构仿真」多段曲目（和声+旋律+颤音+弱噪声打击，非白噪）——
    机器上无真实录音（如实标注）。44.1k 立体声；内存受限 → 并发 ≤ 24。
  - 基线：FFmpeg = 100 分。对每项测 era 与 ffmpeg 的 wall、user+sys CPU、进程峰值 RSS，
    定义 speed=ffmpeg_wall/era_wall，cpu=ffmpeg_cpu/era_cpu，mem=ffmpeg_rss/era_rss；
    合成总分 = 100 * speed^0.6 * (0.5*cpu+0.5*mem)^0.4（>100=era 更优）。
  - 任务：① 单格式逐格式解码（decode→丢弃 PCM，headless）；② 并发伸缩；③ 混杂多格式×时长；
    资源统一取 python getrusage(RUSAGE_CHILDREN)（era 为单进程含池；ffmpeg 为 N 进程合计）。
"""
import argparse, datetime, os, resource, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.normpath(os.path.join(HERE, "..", "..", "build", "tests", "bench_era_pool"))
DATE = datetime.date.today().isoformat()

SONGS = {  # name: (seconds, base_freq)
    "s1": (6, 220),
    "s2": (9, 165),
    "s3": (12, 110),
}
FORMATS = {  # ffmpeg 编码参数（s1 全格式单测用）
    "flac":  ["-c:a", "flac"],
    "wav":   ["-c:a", "pcm_s16le"],
    "mp3":   ["-c:a", "libmp3lame", "-b:a", "192k"],
    "aac":   ["-c:a", "aac", "-b:a", "192k"],
    "vorbis":["-c:a", "libvorbis", "-q:a", "4"],
    "opus":  ["-c:a", "libopus", "-b:a", "128k"],
    "ac3":   ["-c:a", "ac3", "-b:a", "256k"],
    "eac3":  ["-c:a", "eac3", "-b:a", "256k"],
    "mp2":   ["-c:a", "mp2", "-b:a", "192k"],
    "wv":    ["-c:a", "wavpack"],
    "tta":   ["-c:a", "tta"],
    "mka":   ["-c:a", "flac"],   # mka(flac 轨)
    "spx":   ["-ar", "16000", "-ac", "1", "-c:a", "libspeex", "-compression_level", "8"],
}
EXT = {"aac": "m4a", "vorbis": "ogg", "opus": "ogg", "wv": "wv", "mka": "mka",
       "spx": "spx", "tta": "tta", "ac3": "ac3", "eac3": "ec3", "mp2": "mp2",
       "flac": "flac", "wav": "wav", "mp3": "mp3"}

def music_wav(path, sec, f0):
    """和声+旋律+颤音+低噪：更具音乐结构的可复现仿真（非纯噪声）。"""
    expr = ("0.45*sin(2*PI*({f0})*t)+0.30*sin(2*PI*({f0}*1.5)*t)+"
            "0.20*sin(2*PI*({f0}*2.0)*(1+0.05*sin(2*PI*0.5*t))*t)+"
            "0.12*sin(2*PI*({f0}*3.0)*t)*(0.6+0.4*sin(2*PI*2*t))").format(f0=f0)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "aevalsrc=%s:s=44100:d=%d" % (expr, sec),
                    "-ac", "2", "-y", path], check=True)

def _wrap(kind, files, host_max=None):
    py = sys.executable
    wrap = os.path.join(HERE, "_reswrap.py")
    cmd = [py, wrap, kind] + (([str(host_max)] + files) if kind == "era" else files)
    r = subprocess.run(cmd, capture_output=True, text=True)
    d = {}
    for tok in r.stdout.split():
        if "=" in tok:
            k, v = tok.split("=")
            d[k] = float(v)
    return d

TRIALS = 5  # 每项测 5 轮，去一个最高、一个最低，其余取平均（抗偶然）

def _trim_avg(vals):
    vals = sorted(vals)
    if len(vals) <= 2:
        return sum(vals) / len(vals)
    inner = vals[1:-1]  # 去最高与最低
    return sum(inner) / len(inner)

def _measure(kind, files, host_max=None):
    """返回该侧 (wall,cpu,rss) 的 5 轮去极值平均。"""
    w, c, r = [], [], []
    for _ in range(TRIALS):
        d = _wrap(kind, files, host_max)
        w.append(d.get("WALL", 0.0))
        c.append(d.get("CPU", 0.0))
        r.append(d.get("RSS", 0.0))
    return _trim_avg(w), _trim_avg(c), _trim_avg(r)

def run_pair(files, host_max):
    """era（单进程池）与 ffmpeg（N 进程）各 5 轮、去极值取平均。
    返回 dict：era_wall/ffmpeg_wall/era_cpu/ffmpeg_cpu/era_rss/ffmpeg_rss（rss 单位 KB）。"""
    ew, ec, er = _measure("era", files, host_max)
    fw, fc, fr = _measure("ffmpeg", files)
    return {"era_wall": ew, "ffmpeg_wall": fw, "era_cpu": ec, "ffmpeg_cpu": fc,
            "era_rss": er, "ffmpeg_rss": fr}

def scores(d):
    ew, fw = d["era_wall"], d["ffmpeg_wall"]
    if not ew or not fw:
        return None
    sp = fw / ew
    cpu = (d["ffmpeg_cpu"] + 1e-6) / (d["era_cpu"] + 1e-6)
    mem = (max(d["ffmpeg_rss"], 1) ) / (max(d["era_rss"], 1))
    rsrc = 0.5 * cpu + 0.5 * mem
    total = 100.0 * (sp ** 0.6) * (rsrc ** 0.4)
    return sp, cpu, mem, total

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="/tmp/opencode/music")
    ap.add_argument("--maxN", type=int, default=24)
    args = ap.parse_args()
    cor = args.corpus
    os.makedirs(cor, exist_ok=True)
    A = []
    def add(x=""):
        A.append(x)
    add("# EraAudio 常驻内核池 · scorecard 口径扩测（真实曲目→音乐结构仿真 + 资源开销入评分）")
    add("")
    add("> 日期：%s · 基准：**FFmpeg = 100 分**。对每项取 era 与 ffmpeg 的 wall、user+sys CPU、峰值 RSS。" % DATE)
    add("> 评分：speed=ffmpeg_wall/era_wall；cpu=ffmpeg_cpu/era_cpu；mem=ffmpeg_rss/era_rss；")
    add("> 总分=100·speed^0.6·(0.5cpu+0.5mem)^0.4（>100=era 更优）。内存受限→并发≤%d。headless 静音。" % args.maxN)
    add("> 抗偶然：每项 5 轮、各指标去一个最高与最低后取平均。")
    add("> 语料说明（诚实）：机器无真实录音 → 采用可复现的**音乐结构仿真**曲目（和声/旋律/颤音/"
        "低频噪声打击，多段 6/9/12s，44.1k 立体声），非纯白噪、非版权曲目；趋势参考。")
    add("")

    # 生成语料
    files = {}
    for name, (sec, f0) in SONGS.items():
        w = os.path.join(cor, "src_" + name + ".wav")
        music_wav(w, sec, f0)
        for fmt, enc in FORMATS.items():
            f = os.path.join(cor, "%s.%s" % (name, EXT[fmt]))
            if fmt == "mka":
                subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", w,
                                "-c:a", "flac", "-f", "matroska", "-y", f], check=True)
            elif fmt == "spx":
                subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", w] + enc + ["-y", f], check=True)
            else:
                subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", w] + enc + ["-y", f], check=True)
            files.setdefault(fmt, {})[name] = f
    # wav 表列
    fmt_order = ["flac", "wav", "mp3", "aac", "vorbis", "opus", "ac3", "eac3",
                 "mp2", "wv", "tta", "mka", "spx"]

    # 1) 单格式（s1，6s）
    add("## 1. 单格式逐格式解码（s1≈6s）：era vs ffmpeg(=100)")
    add("")
    add("| 格式 | era wall | ffmpeg wall | speed | era cpu s | ffmpeg cpu s | era RSS MB | ffmpeg RSS MB | 总分 |")
    add("|---|---|---|---|---|---|---|---|---|")
    single = {}
    for fmt in fmt_order:
        f = files[fmt]["s1"]
        d = run_pair([f], 1)
        s = scores(d)
        single[fmt] = (d, s)
        sp, cpu, mem, total = s
        add("| %s | %.1fms | %.1fms | %.2f× | %.3f | %.3f | %.1f | %.1f | %.1f |" % (
            fmt, d["era_wall"], d["ffmpeg_wall"], sp, d["era_cpu"], d["ffmpeg_cpu"],
            d["era_rss"] / 1024.0, d["ffmpeg_rss"] / 1024.0, total))
    add("")
    av = sum(x[1][3] for x in single.values()) / len(single)
    add("平均总分：**%.1f**（FFmpeg=100）。" % av)
    add("")

    # 2) 并发伸缩（用 s1 各格式轮转）
    add("## 2. 并发伸缩（s1 各格式轮转 N 路，era 单进程池 vs ffmpeg N 进程）")
    add("")
    add("| N | era wall | ffmpeg wall | era cpu | ffmpeg cpu | era RSS MB | ffmpeg RSS MB | 总分 |")
    add("|---|---|---|---|---|---|---|---|")
    sel_base = [files[fmt]["s1"] for fmt in fmt_order]
    for n in [1, 2, 4, 8, 16, 24]:
        if n > args.maxN:
            continue
        sel = [sel_base[i % len(sel_base)] for i in range(n)]
        d = run_pair(sel, n)
        s = scores(d)
        add("| %d | %.1fms | %.1fms | %.3f | %.3f | %.1f | %.1f | %.1f |" % (
            n, d["era_wall"], d["ffmpeg_wall"], d["era_cpu"], d["ffmpeg_cpu"],
            d["era_rss"] / 1024.0, d["ffmpeg_rss"] / 1024.0, s[3]))
    add("")

    # 3) 混杂（多格式×多时长 s1/s2/s3）
    add("## 3. 混杂并发（s1/s2/s3 各格式交错：多格式 × 6/9/12s）")
    add("")
    add("| N | era wall | ffmpeg wall | era cpu | ffmpeg cpu | era RSS MB | ffmpeg RSS MB | 总分 |")
    add("|---|---|---|---|---|---|---|---|")
    pool = []
    for name in ("s1", "s2", "s3"):
        for fmt in ["flac", "aac", "mp3", "opus", "wv", "ac3"]:
            if fmt in files and name in files[fmt]:
                pool.append(files[fmt][name])
    for n in [8, 16, 24]:
        if n > args.maxN:
            continue
        sel = [pool[i % len(pool)] for i in range(n)]
        d = run_pair(sel, n)
        s = scores(d)
        add("| %d | %.1fms | %.1fms | %.3f | %.3f | %.1f | %.1f | %.1f |" % (
            n, d["era_wall"], d["ffmpeg_wall"], d["era_cpu"], d["ffmpeg_cpu"],
            d["era_rss"] / 1024.0, d["ffmpeg_rss"] / 1024.0, s[3]))
    add("")
    add("> 注：era RSS 为单进程（含 1..N worker 池）；ffmpeg RSS 为 N 进程合计（RUSAGE_CHILDREN 峰值），"
        "CPU 为墙钟内 user+sys 合计。ms 级抖动/语料合成，请比趋势与 ×RT。")
    add("")

    out = os.path.join(HERE, "REPORT_ERA_POOL_SCORE_%s.md" % DATE)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(A) + "\n")
    print("written:", out)

if __name__ == "__main__":
    main()
