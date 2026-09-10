#!/usr/bin/env python3
# ArchoeraMusic — scanner × 自研内核元数据桥 联动 Benchmark
#
# 目的：量化 scanner 经 `zk_metadata_*`（probe-only，无 JSON）直桥自研内核 vs
# 回退 TagLibSharp 的**吞吐/CPU/内存**，并做**正确性对拍**（避免“少做事更快”）。
#
# 用法：
#   python3 scan_kernel_bench.py [--corpus DIR] [--par 1,4,8,16] [--rounds N]
#
# 产物：REPORT_SCAN_KERNEL_<date>.md
import argparse, datetime, os, resource, shutil, sqlite3, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
SCANNER = os.path.abspath(os.path.join(HERE, ".."))
DLL = os.path.join(SCANNER, "bin", "Debug", "net10.0", "archoera-scanner.dll")
KSO = os.path.join(SCANNER, "bin", "Debug", "net10.0", "libarchoera_kernel.so")
TMP = "/tmp/opencode"
DATE = datetime.date.today().isoformat()
OUT = os.path.join(HERE, f"REPORT_SCAN_KERNEL_{DATE}.md")


def build():
    subprocess.run(["dotnet", "build", os.path.join(SCANNER, "scanner.csproj"),
                    "-v", "quiet", "-nologo"], cwd=SCANNER, check=False)


def peak_rss(pid):
    try:
        with open(f"/proc/{pid}/status") as f:
            for l in f:
                if l.startswith("VmHWM:"):
                    return int(l.split()[1]) / 1024.0
    except Exception:
        return 0.0
    return 0.0


def child_cpu():
    r = resource.getrusage(resource.RUSAGE_CHILDREN)
    return r.ru_utime + r.ru_stime


def run_scan(corpus, par, tag):
    db = f"{TMP}/link_{tag}_{par}.db"
    for suf in ("", "-wal", "-shm"):
        try: os.remove(db + suf)
        except OSError: pass
    env = dict(os.environ, ARCHOERA_DB_PATH=db, ARCHOERA_DATA_DIR=f"{TMP}/link_sd_{tag}_{par}",
               SCANNER_MAX_PARALLELISM=str(par))
    peak = [0.0]; stop = threading.Event()
    c0 = child_cpu()
    t0 = time.monotonic()
    p = subprocess.Popen(["dotnet", DLL, "scan", "--dirs", corpus, "--full"],
                         env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def poll():
        while not stop.is_set():
            r = peak_rss(p.pid)
            if r > peak[0]: peak[0] = r
            time.sleep(0.002)
    th = threading.Thread(target=poll, daemon=True); th.start()
    rc = p.wait()
    stop.set(); th.join(timeout=0.2)
    wall = (time.monotonic() - t0) * 1000
    cpu = child_cpu() - c0
    rows = []
    try:
        c = sqlite3.connect(db)
        rows = c.execute("select path,title,codec,duration,sample_rate,channels,bits_per_sample "
                         "from tracks order by path").fetchall()
        c.close()
    except Exception:
        pass
    return {"wall": wall, "cpu": cpu, "rss": peak[0], "rc": rc, "rows": rows, "db": db}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=f"{TMP}/link_corpus")
    ap.add_argument("--par", default="1,4,8,16")
    ap.add_argument("--rounds", type=int, default=1)
    a = ap.parse_args()

    if not os.path.isfile(DLL):
        build()
    pars = [int(x) for x in a.par.split(",")]

    results = {}  # (par, engine) -> dict
    for par in pars:
        for name, use_k in (("kernel", True), ("taglib", False)):
            if not use_k and os.path.exists(KSO):
                shutil.move(KSO, f"{TMP}/kh.link")
            best = None
            for _ in range(max(1, a.rounds)):
                r = run_scan(a.corpus, par, name)
                if best is None or r["wall"] < best["wall"]:
                    best = r
            if not use_k and os.path.exists(f"{TMP}/kh.link"):
                shutil.move(f"{TMP}/kh.link", KSO)
            results[(par, name)] = best
            print(f"par={par} {name}: wall={best['wall']:.0f}ms cpu={best['cpu']:.2f}s "
                  f"rss={best['rss']:.1f}MB tracks={len(best['rows'])} rc={best['rc']}")

    # 正确性对拍（par 最大）：kernel vs taglib 行集合
    cmp_par = pars[-1]
    kr = results[(cmp_par, "kernel")]["rows"]
    tr = results[(cmp_par, "taglib")]["rows"]
    kd = {r[0]: r for r in kr}
    td = {r[0]: r for r in tr}
    common = sorted(set(kd) & set(td))
    mism = []
    for p in common:
        k, t = kd[p], td[p]
        # 比较 codec/采样率/声道/位深/时长（title 允许内核/TagLib 各自策略）
        if (k[2], k[3], k[4], k[5], k[6]) != (t[2], t[3], t[4], t[5], t[6]):
            mism.append((p, k, t))

    A = []
    A.append(f"# Scanner × 自研内核元数据桥 联动 Benchmark（{DATE}）")
    A.append("")
    A.append(f"> 语料：`{a.corpus}`（多格式真实样本，{len(kr) or len(tr)} 文件）。"
             f"scanner 直桥内核 `zk_metadata_*`（probe-only，无 JSON）vs 回退 TagLibSharp。")
    A.append("> 口径：墙钟 monotonic、CPU=user+sys（子进程合计）、峰值 RSS=VmHWM 轮询；"
             f"每配置 {a.rounds} 轮取最快墙钟；核心 pin P 核。")
    A.append("")
    A.append("## 1. 吞吐 / CPU / 内存（kernel vs TagLib）")
    A.append("")
    A.append("| 并行度 | 引擎 | wall ms | files/s | CPU(s) | 峰值 RSS MB | tracks | rc |")
    A.append("|---|---|---|---|---|---|---|---|")
    nfiles = max(len(kr), len(tr), 1)
    for par in pars:
        for name in ("kernel", "taglib"):
            r = results[(par, name)]
            fps = nfiles / (r["wall"] / 1000.0) if r["wall"] > 0 else 0
            A.append(f"| {par} | {name} | {r['wall']:.0f} | {fps:.1f} | {r['cpu']:.3f} | "
                     f"{r['rss']:.1f} | {len(r['rows'])} | {r['rc']} |")
    A.append("")
    A.append("## 2. 正确性对拍（kernel vs TagLib，codec/采样率/声道/位深/时长）")
    A.append("")
    A.append(f"- 共同文件：{len(common)}；字段不一致：**{len(mism)}**")
    if mism:
        A.append("")
        A.append("| 文件 | kernel | taglib |")
        A.append("|---|---|---|")
        for p, k, t in mism[:20]:
            A.append(f"| {os.path.basename(p)} | {k[2:] } | {t[2:]} |")
    A.append("")
    A.append("## 3. 按格式覆盖（kernel 结果）")
    A.append("")
    A.append("| 扩展名 | 数量 | codec |")
    A.append("|---|---|---|")
    byext = {}
    for r in kr:
        ext = os.path.splitext(r[0])[1].lower()
        byext.setdefault(ext, [0, r[2]])
        byext[ext][0] += 1
    for ext in sorted(byext):
        A.append(f"| {ext} | {byext[ext][0]} | {byext[ext][1]} |")
    A.append("")
    A.append("> 说明：小语料下进程启动/DB 写入占比较大；跨机比相对值。内核路径价值在"
             "统一解析（无 JSON）、低内存与共享内核，而非单纯吞吐。")

    with open(OUT, "w") as f:
        f.write("\n".join(A))
    print(f"written {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
