#!/usr/bin/env python3
"""run_bench.py — 语料基准驱动器（Stable/FFmpeg vs EraAudio 解码全矩阵）。

用法:
  run_bench.py [--corpus DIR] [--engine BIN] [--csv FILE] [--reps N]
               [--smp-ms F] [--timeout-s S] [--build-tag TAG] [--mode {0,1,both}]

遍历语料目录所有文件，对每个文件跑 engine-mode 0 与 1（both），聚合多次 rep：
  单行/文件×引擎：rc、ok_reps、wall_best、user_best、peak_rss_max、out_bytes、takeover。

CSV 结果文件同时作为 make_report.py 的输入。进度输出走 stderr。
"""

import argparse
import csv
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_decode as bd  # noqa: E402


def aggregate(reps, mode):
    ok = [r for r in reps if r.get("rc") == 0]
    row = {
        "mode": mode,
        "takeover": reps[0].get("takeover", ""),
        "rc": reps[0].get("rc"),
        "ok_reps": len(ok),
        "wall_best_s": min((r["wall_s"] for r in ok), default=None),
        "user_best_s": min((r["user_s"] for r in ok), default=None),
        "sys_best_s": min((r["sys_s"] for r in ok), default=None),
        "peak_rss_kb": max((r["peak_rss_kb"] for r in reps), default=None),
        "out_bytes": ok[-1].get("out_bytes") if ok else None,
    }
    if row["wall_best_s"] is None:
        row["wall_best_s"] = reps[0].get("wall_s")
        row["user_best_s"] = reps[0].get("user_s")
        row["sys_best_s"] = reps[0].get("sys_s")
    return row


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="/tmp/eng")
    ap.add_argument("--engine", default=os.path.join(here, "..", "..", "build", "archoera-audio-engine"))
    ap.add_argument("--csv", default=os.path.join(here, "data", "BENCH_results.csv"))
    ap.add_argument("--reps", type=int, default=2)
    ap.add_argument("--smp-ms", type=float, default=2.0)
    ap.add_argument("--timeout-s", type=float, default=600.0)
    ap.add_argument("--build-tag", default="")
    ap.add_argument("--mode", default="both", choices=["0", "1", "both"])
    ap.add_argument("--exts", default="wav,flac,wv,mka,m4a,mp3,opus,ogg,aac,ac3,ec3,tta,mp2,ape,alac,dsf,dff,m4b,amr,mpc,wma")
    a = ap.parse_args()

    engine = os.path.abspath(a.engine)
    if not os.path.isfile(engine):
        print(f"错误：引擎不存在 {engine}", file=sys.stderr)
        return 1
    os.makedirs(os.path.dirname(a.csv), exist_ok=True)
    exts = {e.lstrip(".").lower() for e in a.exts.split(",") if e}
    files = sorted(
        os.path.join(a.corpus, n) for n in os.listdir(a.corpus)
        if os.path.isfile(os.path.join(a.corpus, n))
        and not n.startswith(".")
        and os.path.splitext(n)[1].lstrip(".").lower() in exts
    )
    if not files:
        print(f"语料目录为空: {a.corpus}", file=sys.stderr)
        return 1

    modes = [0, 1] if a.mode == "both" else [int(a.mode)]
    out_ogg = os.path.join(a.corpus, ".bench_out.ogg")

    fields = ["build_tag", "file", "size_bytes", "codec", "sr", "ch",
              "dur_s", "mode", "takeover", "rc", "ok_reps", "wall_best_s",
              "user_best_s", "sys_best_s", "peak_rss_kb", "out_bytes"]
    print(f"# build_tag={a.build_tag} engine={engine} corpus={a.corpus} "
          f"reps={a.reps} modes={modes} @ {time.strftime('%F %T')}", file=sys.stderr)

    with open(a.csv, "w", newline="") as fcsv:
        w = csv.DictWriter(fcsv, fieldnames=fields)
        w.writeheader()
        t0 = time.monotonic()
        for idx, f in enumerate(files, 1):
            size = os.path.getsize(f)
            meta = bd.probe_source(f)
            rows_for_file = []
            for mode in modes:
                results = []
                for rep_i in range(max(1, a.reps)):
                    r = bd.run_one(engine, f, mode, out_ogg,
                                   a.smp_ms, a.timeout_s)
                    r.update({"mode": mode})
                    results.append(r)
                    if r.get("timeout") or r["rc"] != 0:
                        break
                row = aggregate(results, mode)
                row.update({
                    "build_tag": a.build_tag,
                    "file": f,
                    "size_bytes": size,
                    "codec": meta.get("codec", ""),
                    "sr": meta.get("sample_rate", ""),
                    "ch": meta.get("channels", ""),
                    "dur_s": round(meta["duration_s"], 3) if meta.get("duration_s") else "",
                })
                w.writerow(row)
                fcsv.flush()
                rows_for_file.append(row)
                st = f"[{idx}/{len(files)}] {os.path.basename(f)} mode={mode} " \
                     f"take={row['takeover']} rc={row['rc']} " \
                     f"wall={row['wall_best_s']}s rss={row['peak_rss_kb']}KB"
                print(st, file=sys.stderr)
            if len(rows_for_file) == 2:
                s0, s1 = rows_for_file
                print(f"  -- {os.path.basename(f)}  mode0_wall={s0['wall_best_s']}  "
                      f"mode1_wall={s1['wall_best_s']}  "
                      f"mode0_rss={s0['peak_rss_kb']}  mode1_rss={s1['peak_rss_kb']}",
                      file=sys.stderr)

    print(f"完成。总耗时 {time.monotonic()-t0:.1f}s → {a.csv}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
