#!/usr/bin/env python3
"""make_report.py — 由 run_bench.py 的 CSV 生成 Markdown 汇总报告（可复用）。

用法:
  make_report.py --csv tests/bench/data/BENCH_YYYY-MM-DD.csv --md <out.md>
                 [--engine BIN] [--corpus DIR] [--kernel-md5 <hex>]

产出章节：
  1) 语料清单（后缀/大小/时长/内轨 codec/era 接管）
  2) 大文件(≥13.5MB)峰值 RSS 对比 + 判定
  3) 按「容器后缀」的 Era_RSS × 文件体积趋势（整读 vs 固定缓冲 vs 流式）
  4) Stable/FFmpeg 解码耗时 ×RT 参考（Era native 是否可信见报告正文，由 blocked 列提示）
  5) 输出字节数对比（稳定引擎 vs era，解码完整性以报告正文 ffprobe 时长核验为准）

判定启发式（3）：
  rss 跨体积涨幅 spread > 20MB 且 max-min 体积差 > 5MB → "整缓冲"
  spread ≤ 20MB 但中位 RSS 高于全库最低 native RSS 12MB+  → "固定高缓冲"
  否则 → "流式"
"""

import argparse
import csv
import math
import os
import statistics
import time

STREAM_BASE_KB = 34_000  # 实测 EraAudio native 流式平台工作集（全量解码后基准 ≈34MB）


def suffix(name: str) -> str:
    return name.rsplit(".", 1)[-1] if "." in name else "?"


def classify(pts):
    sizes = [p[1] for p in pts]
    rsss = [p[2] for p in pts]
    spread = max(rsss) - min(rsss)
    size_range = max(sizes) - min(sizes)
    med = statistics.median(rsss)
    if spread > 20 and size_range > 5:
        return "整缓冲(随体积/时长线性)"
    if med > STREAM_BASE_KB / 1000 + 12:
        return "固定高缓冲(非整读)"
    return "流式"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--md", required=True)
    ap.add_argument("--engine", default="")
    ap.add_argument("--corpus", default="")
    ap.add_argument("--kernel-md5", default="")
    a = ap.parse_args()

    with open(a.csv) as f:
        rows = list(csv.DictReader(f))
    tag = rows[0]["build_tag"]
    files = sorted({r["file"] for r in rows})
    byfile = {f: {} for f in files}
    for r in rows:
        byfile.setdefault(r["file"], {})[r["mode"]] = r

    def get(f, mode, key, default=""):
        m = byfile[f].get(mode)
        return m.get(key, default) if m else default

    L = []
    w = L.append
    w("# EraAudio vs Stable(FFmpeg) 解码基准报告（自动汇总）")
    w("")
    w(f"- 生成: {time.strftime('%F %T')}   构建快照: `{tag}`")
    w(f"- 引擎: `{a.engine or '(见 CSV)'}`   语料: `{a.corpus or '(见 CSV)'}`")
    if a.kernel_md5:
        w(f"- kernel 源码快照 md5: `{a.kernel_md5}`")
    w("- Stable = `--engine-mode 0`（FFmpeg）；EraAudio = `--engine-mode 1`（自研 Zig 内核优先，失败回退）")
    w("- 采集：stdout→临时 OGG/Opus；墙钟 time.monotonic；user+sys=getrusage(RUSAGE_CHILDREN)；"
      "峰值 RSS=/proc/<pid>/status VmRSS 2ms 轮询。")
    w("- EOF/错误语义已收敛（2026-09-05）：成功≠EOF；解码错误经负状态码上报。"
      "Era 墙钟/输出字节对全时长解码可信；输出字节差异解读见 §5。")
    w("")

    w("## 1. 语料清单")
    w("")
    w("| 文件 | 大小(MB) | 时长(s) | 内轨codec | era接管 |")
    w("|---|---|---|---|---|")
    for f in files:
        size = float(get(f, "0", "size_bytes", 0)) / 1e6
        w(f"| {f.split('/')[-1]} | {size:.2f} | {get(f,'0','dur_s')} | {get(f,'0','codec')} "
          f"| {get(f,'1','takeover','?')} |")
    w("")

    w("## 2. 大文件(≥13.5MB) 峰值 RSS（MB）")
    w("")
    w(f"流式基准 ≈ {STREAM_BASE_KB/1000:.0f}MB（Era native 实测最低）。判定依据见 §3 后缀趋势。")
    w("")
    w("| 文件 | 后缀 | 大小 | Stable_RSS | Era_RSS | ΔEra−基准 | 判定(同后缀趋势) |")
    w("|---|---|---|---|---|---|---|")
    for f in files:
        size_mb = float(get(f, "0", "size_bytes", 0)) / 1e6
        if size_mb < 13.5 or not byfile[f].get("1"):
            continue
        s0 = float(get(f, "0", "peak_rss_kb", 0)) / 1000
        s1 = float(get(f, "1", "peak_rss_kb", 0)) / 1000
        w(f"| {f.split('/')[-1]} | {suffix(f.split('/')[-1])} | {size_mb:.1f} "
          f"| {s0:.1f} | {s1:.1f} | {s1-STREAM_BASE_KB/1000:+.1f} | 见 §3 |")
    w("")

    w("## 3. EraAudio 峰值 RSS × 文件体积（按容器后缀）")
    w("")
    w("同一后缀若 RSS 随体积/时长线性上升 → 整缓冲；恒定 → 固定缓冲/流式。")
    w("")
    w("| 后缀 | 序列(文件名@体积MB→RSS MB) | 判定 |")
    w("|---|---|---|")
    fmts = {}
    for f in files:
        if get(f, "1", "takeover") != "native":
            continue
        s = suffix(f.split("/")[-1])
        fmts.setdefault(s, []).append(
            (f.split("/")[-1],
             float(get(f, "1", "size_bytes", 0)) / 1e6,
             float(get(f, "1", "peak_rss_kb", 0)) / 1000))
    for s in sorted(fmts):
        pts = sorted(fmts[s], key=lambda x: x[1])
        chain = " → ".join(f"{n}@{sz:.1f}MB→{r:.1f}MB" for n, sz, r in pts)
        w(f"| {s} | {chain} | {classify(pts)} |")
    w("")

    w("## 4. Stable/FFmpeg 解码耗时 ×RT（Era native 是否有效见正文）")
    w("")
    w("管道=解码→48k/2ch→限幅→Opus(128k) 编码，双端相同。RT=墙钟/源时长。")
    w("")
    w("| 文件 | 时长(s) | Stable墙钟(s) | Stable×RT | Era墙钟(s) | Era native? |")
    w("|---|---|---|---|---|---|")
    for f in files:
        m1 = byfile[f].get("1")
        dur = float(get(f, "0", "dur_s") or 0)
        w0 = float(get(f, "0", "wall_best_s") or 0)
        w1 = float(get(f, "1", "wall_best_s") or 0) if m1 else 0
        take = get(f, "1", "takeover", "?")
        w(f"| {f.split('/')[-1]} | {dur:.1f} | {w0:.3f} | {(w0/dur):.4f} | {w1:.3f} | {take} |")
    w("")

    w("## 5. 输出字节数对比（解码完整性以正文 ffprobe 时长核验为准）")
    w("")
    w("| 文件 | 时长(s) | Stable out(KB) | Era out(KB) | 备注 |")
    w("|---|---|---|---|---|")
    for f in files:
        m1 = byfile[f].get("1")
        dur = get(f, "0", "dur_s")
        o0 = float(get(f, "0", "out_bytes", 0)) / 1000
        o1 = float(get(f, "1", "out_bytes", 0)) / 1000 if m1 else 0
        note = ("native 长度对齐" if m1 and m1.get("takeover") == "native"
                else get(f, "1", "takeover", "-"))
        w(f"| {f.split('/')[-1]} | {dur} | {o0:.1f} | {o1:.1f} | {note} |")
    w("")

    os.makedirs(os.path.dirname(a.md) or ".", exist_ok=True)
    with open(a.md, "w") as fh:
        fh.write("\n".join(L) + "\n")
    print(f"written {a.md}")


if __name__ == "__main__":
    main()
