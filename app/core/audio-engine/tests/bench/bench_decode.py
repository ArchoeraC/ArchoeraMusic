#!/usr/bin/env python3
"""bench_decode.py — 单次解码基准 worker（EraAudio/Stable 引擎解码测量）。

用法:
  bench_decode.py <engine_bin> <file> <engine_mode> <out_ogg> [--reps N] [--smp-ms F] [--timeout-s S]

对 <file> 以 <engine_mode>（0=Stable/FFmpeg，1=EraAudio 自研优先）跑 N 次解码，
stdout 写 <out_ogg>（临时文件，结束后删除），测量每 rep：
  墙钟 wall_s（time.monotonic）、子进程 user+sys CPU（getrusage RUSAGE_CHILDREN）、
  峰值 RSS（/proc/<pid>/status VmRSS 轮询）、退出码 rc、输出字节 out_bytes，
  以及接管方 takeover（native / ffmpeg / crash，解析 stderr）。

stdout 每行输出一个 JSON 结果；进度/诊断走 stderr。
"""

import argparse
import json
import os
import resource
import subprocess
import sys
import threading
import time


def read_vmrss_kb(pid: int) -> int | None:
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        return None
    return None


def rss_sampler(pid: int, interval_s: float, stop: threading.Event, out_peak):
    peak = 0
    while not stop.is_set():
        v = read_vmrss_kb(pid)
        if v is not None and v > peak:
            peak = v
        stop.wait(interval_s)
    v = read_vmrss_kb(pid)
    if v is not None and v > peak:
        peak = v
    out_peak.append(peak)


def probe_source(path: str) -> dict:
    """ffprobe 源文件元数据（音频流优先）。失败返回空 dict。"""
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-print_format", "json",
             "-show_format", "-show_streams", path],
            capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            return {}
        j = json.loads(r.stdout)
        stream = None
        for s in j.get("streams", []):
            if s.get("codec_type") == "audio":
                stream = s
                break
        if stream is None:
            stream = (j.get("streams") or [{}])[0]
        dur_s = None
        try:
            dur_s = float(j.get("format", {}).get("duration"))
        except (TypeError, ValueError):
            try:
                dur_s = float(stream.get("duration"))
            except (TypeError, ValueError):
                dur_s = None
        return {
            "codec": stream.get("codec_name", ""),
            "sample_rate": stream.get("sample_rate", ""),
            "channels": stream.get("channels", ""),
            "duration_s": dur_s,
            "bit_depth": stream.get("bits_per_raw_sample")
                         or stream.get("bits_per_sample") or "",
        }
    except Exception:
        return {}


def parse_stderr(log: str, mode: int, rc: int) -> str:
    if mode == 0:
        return "ffmpeg"
    if "自研内核接管" in log:
        return "native"
    if "回退 FFmpeg" in log or "未接管" in log:
        return "fallback"
    if rc != 0:
        return "crash"
    return "ffmpeg"


def run_one(engine: str, path: str, mode: int, out_ogg: str,
            smp_ms: float, timeout_s: float) -> dict:
    log_path = out_ogg + ".err.log"
    try:
        with open(out_ogg, "wb") as fout, open(log_path, "w") as ferr:
            ru0 = resource.getrusage(resource.RUSAGE_CHILDREN)
            t0 = time.monotonic()
            proc = subprocess.Popen(
                [engine, path, "--engine-mode", str(mode)],
                stdout=fout, stderr=ferr)
            stop = threading.Event()
            peak = []
            th = threading.Thread(target=rss_sampler,
                                  args=(proc.pid, smp_ms / 1000.0, stop, peak),
                                  daemon=True)
            th.start()
            try:
                proc.wait(timeout=timeout_s)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
                stop.set()
                th.join(timeout=2)
                return {"rc": -9, "timeout": True, "peak_rss_kb": (peak or [0])[0]}
            wall_s = time.monotonic() - t0
            ru1 = resource.getrusage(resource.RUSAGE_CHILDREN)
            stop.set()
            th.join(timeout=2)
        out_bytes = os.path.getsize(out_ogg)
        with open(log_path) as f:
            log = f.read()
        return {
            "rc": proc.returncode,
            "wall_s": round(wall_s, 4),
            "user_s": round(ru1.ru_utime - ru0.ru_utime, 4),
            "sys_s": round(ru1.ru_stime - ru0.ru_stime, 4),
            "peak_rss_kb": (peak or [0])[0],
            "out_bytes": out_bytes,
            "takeover": parse_stderr(log, mode, proc.returncode),
            "timeout": False,
        }
    finally:
        for p in (out_ogg, log_path):
            try:
                os.unlink(p)
            except OSError:
                pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("engine")
    ap.add_argument("file")
    ap.add_argument("engine_mode", type=int)
    ap.add_argument("out_ogg")
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--smp-ms", type=float, default=2.0)
    ap.add_argument("--timeout-s", type=float, default=600.0)
    a = ap.parse_args()
    meta = probe_source(a.file)
    results = []
    for _ in range(max(1, a.reps)):
        r = run_one(a.engine, a.file, a.engine_mode, a.out_ogg,
                    a.smp_ms, a.timeout_s)
        r.update({"mode": a.engine_mode, "meta": meta})
        results.append(r)
        if r.get("timeout") or r.get("rc") not in (0,):
            if r["rc"] != 0:
                break
    print(json.dumps(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
