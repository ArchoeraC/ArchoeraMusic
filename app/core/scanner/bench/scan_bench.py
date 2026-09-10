#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scanner 吞吐基线：当前（去 async）vs 旧版（0a24c9cd，Channel+async）对比。

用法：python3 scan_bench.py --files 1000
产物：REPORT_SCANNER_ASYNC_<date>.md
"""
import argparse, datetime, os, resource, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
SCANNER = os.path.normpath(os.path.join(HERE, ".."))          # app/core/scanner
DATE = datetime.date.today().isoformat()
OLD_WORKTREE = "/tmp/opencode/scanner-old/app/core/scanner"


def gen_corpus(dirpath, n):
    os.makedirs(dirpath, exist_ok=True)
    fmts = [("flac", "flac"), ("m4a", "aac"), ("mp3", "libmp3lame")]
    existing = [f for f in os.listdir(dirpath) if f.endswith((".flac", ".m4a", ".mp3"))]
    if len(existing) >= n:
        return
    for i in range(n):
        ext, codec = fmts[i % 3]
        f = os.path.join(dirpath, f"t{i:05d}.{ext}")
        if os.path.exists(f):
            continue
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
             "-i", f"sine=frequency={300 + (i % 200)}:duration=0.6:sample_rate=44100",
             "-ac", "2", "-c:a", codec, "-y", f], check=True)


def dll_for(project_dir):
    for root, _dirs, files in os.walk(os.path.join(project_dir, "bin")):
        if "archoera-scanner.dll" in files and os.sep + "Release" + os.sep in root:
            return os.path.join(root, "archoera-scanner.dll")
    raise FileNotFoundError("archoera-scanner.dll (Release) not found under " + project_dir)


def run_scan(dll, corpus, db, parallelism):
    env = dict(os.environ)
    env["ARCHOERA_DB_PATH"] = db
    env["SCANNER_MAX_PARALLELISM"] = str(parallelism)
    env["ARCHOERA_DATA_DIR"] = tempfile.mkdtemp(prefix="scanbench-data-")
    t0 = time.monotonic()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    p = subprocess.Popen(["dotnet", dll, "scan", "--dirs", corpus, "--full"],
                         env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rss_kb = 0
    while p.poll() is None:
        try:
            with open(f"/proc/{p.pid}/status") as fh:
                for line in fh:
                    if line.startswith("VmHWM:"):
                        rss_kb = max(rss_kb, int(line.split()[1]))
                        break
        except OSError:
            break
        time.sleep(0.002)
    p.wait()
    wall = (time.monotonic() - t0) * 1000.0
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (after.ru_utime + after.ru_stime) - (before.ru_utime + before.ru_stime)
    wal = os.path.getsize(db + "-wal") if os.path.exists(db + "-wal") else 0
    dbsz = os.path.getsize(db) if os.path.exists(db) else 0
    rows = -1
    try:
        import sqlite3
        con = sqlite3.connect(db)
        rows = con.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
        con.close()
    except Exception:
        pass
    return {"wall": wall, "rss": rss_kb, "cpu": cpu, "db": dbsz, "wal": wal,
            "rc": p.returncode, "rows": rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--files", type=int, default=1000)
    ap.add_argument("--parallelism", type=int, default=8)
    ap.add_argument("--corpus", default="/tmp/opencode/scan_corpus")
    args = ap.parse_args()

    gen_corpus(args.corpus, args.files)

    # 旧版 worktree（若不存在则创建并构建）
    if not os.path.isdir(OLD_WORKTREE):
        subprocess.run(["git", "-C", SCANNER, "worktree", "add", OLD_WORKTREE, "0a24c9cd"], check=True)
    subprocess.run(["dotnet", "build", os.path.join(OLD_WORKTREE, "scanner.csproj"),
                    "-c", "Release"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["dotnet", "build", os.path.join(SCANNER, "scanner.csproj"),
                    "-c", "Release"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    old_dll = dll_for(OLD_WORKTREE)
    new_dll = dll_for(SCANNER)

    rows = []
    for tag, dll in (("旧版(Channel+async)", old_dll), ("新版(去async)", new_dll)):
        db = f"/tmp/opencode/scan_{'old' if 'old' in dll else 'new'}_{os.getpid()}.db"
        for suffix in ("", "-wal", "-shm"):
            try: os.remove(db + suffix)
            except OSError: pass
        # 预热一次（JIT/缓存），再正式测
        run_scan(dll, args.corpus, db + ".warm", args.parallelism)
        for suffix in ("", "-wal", "-shm"):
            try: os.remove(db + ".warm" + suffix)
            except OSError: pass
        r = run_scan(dll, args.corpus, db, args.parallelism)
        r["files"] = args.files
        r["fps"] = args.files / (r["wall"] / 1000.0) if r["wall"] > 0 else 0
        rows.append((tag, r))

    A = []
    A.append("# Scanner 去 async 重构 · 吞吐基线对比")
    A.append("")
    A.append(f"> 日期 {DATE} · 语料 {args.files} 个小文件（flac/aac/mp3 轮转，各 0.6s）· "
             f"并行度 {args.parallelism} · headless（stdout/stderr 丢弃）· 预热一次后正式测一次。")
    A.append(f"> 旧版 = `0a24c9cd`（Channel<Action>+Task 写循环 + Parallel.ForEachAsync）；"
             f"新版 = 去 async（BlockingCollection+专用写线程 + Parallel.For + 同步 Scan）。")
    A.append("")
    A.append("| 版本 | wall ms | files/s | user+sys s | 峰值 RSS MB | DB MB | WAL MB | tracks 行 | rc |")
    A.append("|---|---|---|---|---|---|---|---|---|")
    for tag, r in rows:
        A.append("| %s | %.0f | %.1f | %.2f | %.1f | %.1f | %.1f | %s | %d |" % (
            tag, r["wall"], r["fps"], r["cpu"], r["rss"] / 1024.0,
            r["db"] / 1048576.0, r["wal"] / 1048576.0, r.get("rows"), r["rc"]))
    if len(rows) == 2:
        o, n = rows[0][1], rows[1][1]
        A.append("")
        A.append("**对比**：wall 变化 **%.1f%%**（%.0f→%.0f ms）；files/s **%.1f→%.1f**（%.1f×）；"
                 "CPU %.2f→%.2f s；峰值 RSS %.1f→%.1f MB。" % (
                     (n["wall"] - o["wall"]) / o["wall"] * 100 if o["wall"] else 0,
                     o["wall"], n["wall"], o["fps"], n["fps"],
                     (n["fps"] / o["fps"]) if o["fps"] else 0,
                     o["cpu"], n["cpu"], o["rss"] / 1024.0, n["rss"] / 1024.0))
    A.append("")
    A.append("> 注：单次墙钟，含 dotnet 进程启动（~50-100ms）；files/s 受小文件主导（解析/写占比），"
             "真实大文件与纯 tag 扫描趋势另测。跨机请比相对变化。")
    out = os.path.join(HERE, f"REPORT_SCANNER_ASYNC_{DATE}.md")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(A) + "\n")
    print("written:", out)
    for tag, r in rows:
        print(tag, r)


if __name__ == "__main__":
    main()
