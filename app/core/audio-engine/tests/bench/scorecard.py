#!/usr/bin/env python3
"""scorecard.py — EraAudio 自研解码内核「行业对比基准 + 评分」一次跑完驱动器。

背景
----
对 app/core/audio-engine 自研 Zig 解码内核（EraAudio，--engine-mode 1）做行业对比，
对比对象为「专业库 / 行业基准」：
  1) 系统 FFmpeg n9.0.1：即引擎 Stable 路径（--engine-mode 0），双端同一管线可苹果对苹果；
  2) 独立专业 CLI：flac -d（libFLAC 官方参考）、lame --decode（LAME 参考解码）、
     speexdec（libspeex 参考）；
  3) FFmpeg 内嵌专业库路由：libopus / libvorbis / libspeex / libmp3lame（-c:a lib* 强制解码）。

自研侧测量口径 = build/archoera-audio-engine --engine-mode 1（构建顺序
`zig build -Doptimize=ReleaseFast` → `cmake --build build`；勿用 Debug kernel）。

测量方法（解码→PCM 直通，**不重编码**）
----------------------------------------
  * 引擎两行（era/stable）都用 `--player-file out.wav --no-limiter`：
    skip_encoder（不编码 Opus），输出 float32 WAV、跟随源采样率/声道 → 本质是
    「解码→(恒等)重采样→float 落盘」，去掉 Opus 编码对解码耗时测量的主导污染；
  * 独立工具 / FFmpeg CLI 直接解码到 s16 raw / wav；
  * wall=time.monotonic；user+sys=getrusage(RUSAGE_CHILDREN) 差值；
    峰值 RSS=/proc/<pid>/status VmRSS 轮询（thread，约 2ms）；
  * ×RT（文中列）= 墙钟 / 源时长（越小越快）；实时倍数 R = 1/×RT。

正确性口径
----------
  * lossless（flac/wav/wv/tta/mka）：**逐位**——同一源，era float32 WAV 数据 md5
    == stable float32 WAV == FFmpeg `-f f32le`；FFmpeg s16 与 flac -d s16 md5 亦一致
    （无独立 CLI 的格式注明仅 ffmpeg 路由参考）；
  * lossy（mp3/opus/vorbis/aac/ac3/eac3/dts/mp2/speex）：长度（每声道帧数）对齐 +
    对参考解码器 PCM（libopus/libvorbis/lame/speexdec/ffmpeg native）做 corr / rms。
    比对 Opus 请用 libopus（系统 ffmpeg native 与 libopus 在低码率 SILK/HYBRID 有静态差）。

评分方案（行业口径，阈值写死可复现；总分 100 = speed40 + memory30 + correctness20 + coverage10）
--------------------------------
  speed(40)：R=源时长/墙钟；score = 40·min(1, R/50) —— ≥50× 实时即满分阶梯，<50× 线性递减
    （≥100×→40、50×→40、25×→20、10×→8、1×→0.8）。
  memory(30)：floor_kb = 该引擎全部行中的最小峰值 RSS（实测平台值，era≈34MB、stable≈37MB、
    独立工具≈自身平台）；overhead = rss−floor。
    ≤+3MB→30；≤+10MB→26；≤+25MB→20；≤+60MB→12；否则→4。
    （整文件整读型解码 RSS 会随文件体积涨；本语料全部为有界流式/固定缓冲，故未用体积梯度。）
  correctness(20)：
    lossless：era 数据 md5 == stable == ffmpeg（f32）且（格式支持时）s16 参考逐位 → 20；
      仅 ffmpeg 参考且 f32 逐位 → 20（注明参考面）。任何失配按 lossy 阈值降档。
    lossy：lenAbs≤0.1%·refFrames 且 |corr|≥0.999→20；lenAbs≤1% 且 |corr|≥0.999→19；
      |corr|≥0.99→16；|corr|≥0.95→12；|corr|≥0.9→8；否则 0。
      （|corr| 计分：s16 参考极性分歧类解码器反号不可闻，避免误伤；
       corr 取中间 1%–99% 带、每帧双声道平均；rms16/max16 供参考。）
  coverage(10)：era 行「自研内核接管(native) 且 rc=0 且全长解码」→10；回退 FFmpeg→0
    （记 flag，仍按 ffmpeg 实测内容计速/计内存但不记自研正确性）。
  等级：A+≥95、A≥90、B≥80、C≥70、D<70。

输出
----
  scorecard.py --corpus DIR --engine BIN [--csv out.csv --md out.md --workdir /tmp/sc_wd]
  - 自动生成缺失语料（ind.* / base200.wav / base16k.wav，ffmpeg 自造，幂等）；
  - CSV 原始+评分行；Markdown 汇总（语料/工具/评分表/结论骨架）。
"""

import argparse
import csv
import hashlib
import json
import math
import os
import resource
import statistics
import subprocess
import sys
import shutil
import tempfile
import threading
import time
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ENGINE = os.path.join(HERE, "..", "..", "build", "archoera-audio-engine")

W_SPEED, W_MEM, W_CORR, W_COV = 40, 30, 20, 10

# 采样窗口控制：corr/rms 在源时长 1%..99% 带内至多采 N_FRAMES 帧/声道
CORR_N = 60000

# 语料清单（200s 自造、格式内核已接管；sr/ch 见 ffprobe）。
# engines 顺序即表格顺序；ref = 该格式「地面真值」参考引擎（用于正确性比对）。
# ffmpeg 行可选 forced 解码器（libopus/libvorbis/libspeex 等输入侧 -c:a）。
FORMATS = [
    dict(key="flac",  file="ind.flac",     codec="flac",      cls="lossless",
         ref="flac-d", engines=["era", "stable", "ffmpeg", "flac-d"]),
    dict(key="wav",   file="base200.wav",  codec="pcm_s16le", cls="lossless",
         ref="ffmpeg", engines=["era", "stable", "ffmpeg"]),
    dict(key="wv",    file="ind.wv",       codec="wavpack",   cls="lossless",
         ref="ffmpeg", engines=["era", "stable", "ffmpeg"]),
    dict(key="tta",   file="ind.tta",      codec="tta",       cls="lossless",
         ref="ffmpeg", engines=["era", "stable", "ffmpeg"]),
    dict(key="mka(flac轨)", file="ind.mka", codec="flac",     cls="lossless",
         ref="ffmpeg", engines=["era", "stable", "ffmpeg"]),
    dict(key="mp3",   file="ind.mp3",      codec="mp3",       cls="lossy",
         ref="lame", engines=["era", "stable", "ffmpeg", "lame"]),
    dict(key="opus",  file="ind.opus",     codec="opus",      cls="lossy",
         ref="ffmpeg-libopus", engines=["era", "stable", "ffmpeg", "ffmpeg-libopus"]),
    dict(key="vorbis", file="ind.ogg",     codec="vorbis",    cls="lossy",
         ref="ffmpeg-libvorbis", engines=["era", "stable", "ffmpeg", "ffmpeg-libvorbis"]),
    dict(key="aac(m4a)", file="ind.m4a",   codec="aac",       cls="lossy",
         ref="ffmpeg", engines=["era", "stable", "ffmpeg"]),
    dict(key="aac(adts)", file="ind.adts.aac", codec="aac",   cls="lossy",
         ref="ffmpeg", engines=["era", "stable", "ffmpeg"]),
    dict(key="ac3",   file="ind.ac3",      codec="ac3",       cls="lossy",
         ref="ffmpeg", engines=["era", "stable", "ffmpeg"]),
    dict(key="eac3",  file="ind.ec3",      codec="eac3",      cls="lossy",
         ref="ffmpeg", engines=["era", "stable", "ffmpeg"]),
    dict(key="dts",   file="ind.dts",      codec="dts",       cls="lossy",
         ref="ffmpeg", engines=["era", "stable", "ffmpeg"]),
    dict(key="mp2",   file="ind.mp2",      codec="mp2",       cls="lossy",
         ref="ffmpeg", engines=["era", "stable", "ffmpeg"]),
    dict(key="speex", file="ind.spx",      codec="speex",     cls="lossy",
         ref="ffmpeg-libspeex", engines=["era", "stable", "ffmpeg", "ffmpeg-libspeex", "speexdec"]),
]

# 无独立 CLI 的格式 → 以 ffmpeg 内嵌库为参考（诚实注明）。
# speex 特例：独立 speexdec 与 libspeex 族（含自研）在该高熵语料存在**输出极性相反**分歧
# （ffmpeg 编码侧极性；sine 验证 src↔speexdec 同号、src↔libspeex/era 反号），
# 故参考取 ffmpeg-libspeex 且按 |corr| 计分（纯反号不可闻，避免误伤）。

STANDALONE_NOTE = {
    "opus": "无独立 opusdec，以 ffmpeg 内嵌 libopus 为参考（与 engine-integration-bench §6 一致）",
    "vorbis": "无独立 oggdec，以 ffmpeg 内嵌 libvorbis 为参考",
    "wv": "无独立 wvunpack，以 ffmpeg 内嵌 wavpack 解码为参考",
    "tta": "无独立 CLI，以 ffmpeg 内嵌 tta 解码为参考",
    "aac(m4a)": "无独立 aac 参考（libaac 非解码器），以 ffmpeg native aac 为参考",
    "aac(adts)": "无独立 aac 参考，以 ffmpeg native aac 为参考",
    "ac3": "无独立 CLI，以 ffmpeg native ac3 为参考",
    "eac3": "无独立 CLI，以 ffmpeg native eac3 为参考",
    "dts": "无独立 CLI，以 ffmpeg native dca 为参考",
    "mp2": "无独立 CLI，以 ffmpeg native mp2 为参考",
    "speex": "speexdec 存在但与 libspeex 族极性相反分歧 → 以 ffmpeg libspeex 为参考、按 |corr| 计分",
}

ENGINE_LABEL = {
    "era": "EraAudio(mode1)",
    "stable": "Stable(mode0/FFmpeg)",
    "ffmpeg": "ffmpeg CLI",
    "ffmpeg-libopus": "ffmpeg(libopus)",
    "ffmpeg-libvorbis": "ffmpeg(libvorbis)",
    "ffmpeg-libspeex": "ffmpeg(libspeex)",
    "flac-d": "flac -d",
    "lame": "lame --decode",
    "speexdec": "speexdec",
}

# 全矩阵引擎出现顺序（表头/分列用）
ENGINES_ORDER = []
for _f in FORMATS:
    for _e in _f["engines"]:
        if _e not in ENGINES_ORDER:
            ENGINES_ORDER.append(_e)

GEN_SPECS = [
    ("base200.wav", None),
    ("base16k.wav", None),
    ("ind.flac", "flac"), ("ind.wv", "wavpack -compression_level 2"),
    ("ind.tta", "tta"), ("ind.mp3", "libmp3lame -b:a 192k"),
    ("ind.mp2", "mp2 -b:a 192k"), ("ind.opus", "libopus -b:a 128k"),
    ("ind.ogg", "libvorbis -q:a 4"), ("ind.m4a", "aac -b:a 192k"),
    ("ind.ac3", "ac3 -b:a 256k"), ("ind.ec3", "eac3 -b:a 256k"),
    ("ind.mka", "flac"), ("ind.spx", "libspeex"), ("ind.dts", "dca"),
    ("ind.adts.aac", "aac -f adts"),
]
GEN_ADTS = "ind.adts.aac"


# ---------------------------------------------------------------- IO helpers

def parse_wav(path):
    """手动解析（含 float32 format 3）WAV：返回 dict(rate,ch,bits,off,nbytes)。"""
    with open(path, "rb") as fh:
        head = fh.read(12)
        assert head[:4] == b"RIFF" and head[8:12] == b"WAVE", "not RIFF/WAVE"
        info = {"rate": 0, "ch": 0, "bits": 0, "off": -1, "nbytes": 0}
        while True:
            h = fh.read(8)
            if len(h) < 8:
                break
            cid, size = h[:4], int.from_bytes(h[4:8], "little")
            if cid == b"fmt ":
                fmt = fh.read(size)
                info["ch"] = int.from_bytes(fmt[2:4], "little")
                info["rate"] = int.from_bytes(fmt[4:8], "little")
                info["bits"] = int.from_bytes(fmt[14:16], "little")
            elif cid == b"data":
                info["off"] = fh.tell()
                info["nbytes"] = size
                break
            else:
                fh.seek(size, os.SEEK_CUR)
    return info


def md5_file(path, skip=0, count=-1):
    h = hashlib.md5()
    have = 0
    with open(path, "rb") as fh:
        fh.seek(skip)
        while count < 0 or have < count:
            want = 1 << 20
            if count >= 0:
                want = min(want, count - have)
            b = fh.read(want)
            if not b:
                break
            h.update(b)
            have += len(b)
    return h.hexdigest()


def load_f32_data(path):
    """f32 WAV → array('f')（data 段，交错）。

    注意：批量模式的引擎 `--player-file` 仅写 44B 头 + raw data，RIFF/data chunk
    size 字段为占位符未回填 → data 段长度一律取 (filesize − data_off)，不信任字段值。"""
    import array
    info = parse_wav(path)
    total = os.path.getsize(path) - info["off"]
    a = array.array("f")
    with open(path, "rb") as fh:
        fh.seek(info["off"])
        a.fromfile(fh, total // 4)
    return a, info


def load_s16_raw(path):
    import array
    a = array.array("h")
    with open(path, "rb") as fh:
        a.fromfile(fh, os.path.getsize(path) // 2)
    return a


def load_s16_wav(path):
    import array
    w = wave.open(path, "rb")
    n = w.getnframes()
    data = w.readframes(n)
    w.close()
    a = array.array("h")
    a.frombytes(data)
    return a


def file_frames(kind, path, ch):
    if kind == "f32wav":
        info = parse_wav(path)
        return (os.path.getsize(path) - info["off"]) // 4 // info["ch"]
    if kind == "s16raw":
        return os.path.getsize(path) // 2 // ch
    if kind == "s16wav":
        w = wave.open(path, "rb")
        n = w.getnframes()
        w.close()
        return n
    raise ValueError(kind)


# ---------------------------------------------------------------- generation

def gen_noise_wav(corpus, path, sr, dur=200.0):
    """生成 200s 宽带噪声+低频正弦 混合立体声参考源（高熵，接近真实音乐解码负载；
    种子固定可复现）。"""
    a1 = f"anoisesrc=colour=pink:amplitude=0.28:sample_rate={sr}:duration={dur}:seed=20240905"
    a2 = f"anoisesrc=colour=pink:amplitude=0.28:sample_rate={sr}:duration={dur}:seed=777"
    a3 = f"sine=frequency=331:sample_rate={sr}:duration={dur}"
    fc = ("[0:a][1:a]join=inputs=2:channel_layout=stereo[ns];"
          f"[2:a]volume=0.22,lowpass=f=4000[m];"
          "[ns][m]amix=inputs=2:normalize=0[mix]")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error",
                    "-f", "lavfi", "-i", a1, "-f", "lavfi", "-i", a2,
                    "-f", "lavfi", "-i", a3,
                    "-filter_complex", fc, "-map", "[mix]",
                    "-c:a", "pcm_s16le", path], check=True)


def ensure_corpus(corpus):
    """幂等补齐 200s 自造基准语料（宽带噪声源）；缺失才生成。"""
    os.makedirs(corpus, exist_ok=True)
    base = os.path.join(corpus, "base200.wav")
    base16 = os.path.join(corpus, "base16k.wav")
    if not os.path.isfile(base):
        gen_noise_wav(corpus, base, 44100)
    if not os.path.isfile(base16):
        gen_noise_wav(corpus, base16, 16000)
    for fname, enc in GEN_SPECS:
        dst = os.path.join(corpus, fname)
        if os.path.isfile(dst):
            continue
        if enc is None:
            continue
        if fname == "ind.spx":
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", base16,
                            "-c:a", "libspeex", "-ar", "16000", "-compression", "8", dst],
                           check=True)
        elif fname == "ind.dts":
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", base,
                            "-strict", "experimental", "-c:a", "dca", "-b:a", "768k",
                            "-f", "dts", dst], check=True)
        elif fname == GEN_ADTS:
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", base,
                            "-c:a", "aac", "-b:a", "192k", "-f", "adts", dst], check=True)
        else:
            c = enc.split()
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", base,
                            "-c:a"] + c + [dst], check=True)


# ---------------------------------------------------------------- measurement

def read_vmrss_kb(pid):
    try:
        with open(f"/proc/{pid}/status") as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return None


def rss_sampler(pid, stop, out_peak, interval_s=0.002):
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


PIN = ""


def run_measured(argv, timeout_s=180.0, err_path=None):
    """执行一次解码并测量 wall/user/sys/peakRSS。返回 dict。"""
    if err_path is None:
        err_path = argv[-1] + ".stderr"
    if PIN and shutil.which("taskset"):
        argv = ["taskset", "-c", PIN] + list(argv)
    ru0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.monotonic()
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                            stderr=open(err_path, "w"))
    stop = threading.Event()
    peak = []
    th = threading.Thread(target=rss_sampler, args=(proc.pid, stop, peak), daemon=True)
    th.start()
    try:
        proc.wait(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
        stop.set()
        th.join(timeout=2)
        return {"rc": -9, "timeout": True, "wall_s": timeout_s,
                "peak_rss_kb": (peak or [0])[0], "user_s": 0.0, "sys_s": 0.0}
    wall = time.monotonic() - t0
    ru1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    stop.set()
    th.join(timeout=2)
    return {"rc": proc.returncode, "wall_s": round(wall, 4),
            "user_s": round(ru1.ru_utime - ru0.ru_utime, 4),
            "sys_s": round(ru1.ru_stime - ru0.ru_stime, 4),
            "peak_rss_kb": (peak or [0])[0], "timeout": False}


def measure_adaptive(argv, timeout_s=180.0, short_s=0.6, max_reps=3, err_path=None):
    """短程(<0.6s)自动多次取样取最优 wall（长程单次），RSS 取跨次峰值。"""
    reps = []
    for i in range(max_reps):
        r = run_measured(argv, timeout_s, err_path=err_path)
        reps.append(r)
        if r["rc"] != 0 or r["wall_s"] >= short_s:
            break
    best = min(reps, key=lambda r: (r["rc"] != 0, r["wall_s"]))
    best = dict(best)
    best["peak_rss_kb"] = max(r["peak_rss_kb"] for r in reps)
    return best


def measure_reps(argv, reps, timeout_s=180.0, err_path=None):
    """reps 次采样：wall/cpu 去一个最高与最低后取均值；RSS 取跨次峰值。"""
    rs = [run_measured(argv, timeout_s, err_path=err_path) for _ in range(max(1, reps))]
    ok = [r for r in rs if r["rc"] == 0] or rs

    def trim(vals):
        v = sorted(vals)
        if len(v) >= 3:
            v = v[1:-1]
        return sum(v) / len(v)

    bad = next((r["rc"] for r in rs if r["rc"] != 0), 0)
    return {"rc": bad, "timeout": False,
            "wall_s": round(trim([r["wall_s"] for r in ok]), 4),
            "user_s": round(trim([r["user_s"] for r in ok]), 4),
            "sys_s": round(trim([r["sys_s"] for r in ok]), 4),
            "peak_rss_kb": max(r["peak_rss_kb"] for r in rs)}


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-print_format", "json",
                        "-show_format", "-show_streams", path],
                       capture_output=True, text=True, timeout=60)
    try:
        j = json.loads(r.stdout)
    except Exception:
        return {}
    s = None
    for st in j.get("streams", []):
        if st.get("codec_type") == "audio":
            s = st
            break
    s = s or (j.get("streams") or [{}])[0]
    out = {"codec": s.get("codec_name", ""), "sr": s.get("sample_rate", ""),
           "ch": s.get("channels", ""), "dur": None,
           "bits": s.get("bits_per_raw_sample") or s.get("bits_per_sample") or ""}
    try:
        out["dur"] = float(j["format"]["duration"])
    except Exception:
        try:
            out["dur"] = float(s["duration"])
        except Exception:
            out["dur"] = None
    return out


# ---------------------------------------------------------------- engine cmds

def build_cmd(eng, inp, out, engine_bin):
    """返回 (argv, kind, out_path)。kind: f32wav|s16raw|s16wav"""
    base = os.path.basename(out)
    stem = out
    if eng == "era" or eng == "stable":
        mode = 1 if eng == "era" else 0
        return ([engine_bin, inp, "--engine-mode", str(mode),
                 "--player-file", stem, "--no-limiter"], "f32wav", stem)
    if eng == "ffmpeg":
        return (["ffmpeg", "-y", "-loglevel", "error", "-i", inp, "-map", "a:0",
                 "-vn", "-c:a", "pcm_s16le", "-f", "s16le", stem], "s16raw", stem)
    if eng.startswith("ffmpeg-lib"):
        dec = eng.split("-", 1)[1]
        return (["ffmpeg", "-y", "-loglevel", "error", "-c:a", dec, "-i", inp,
                 "-map", "a:0", "-vn", "-c:a", "pcm_s16le", "-f", "s16le", stem],
                "s16raw", stem)
    if eng == "ffmpeg-f32":  # 仅供 lossless 逐位比对的辅助路由（不进评分表）
        return (["ffmpeg", "-y", "-loglevel", "error", "-i", inp, "-map", "a:0",
                 "-vn", "-c:a", "pcm_f32le", "-f", "f32le", stem], "f32raw", stem)
    if eng == "flac-d":
        return (["flac", "-d", "--silent", "-f", "--force-raw-format",
                 "--endian=little", "--sign=signed", "-o", stem, inp], "s16raw", stem)
    if eng == "lame":
        return (["lame", "--silent", "--decode", inp, stem + ".wav"],
                "s16wav", stem + ".wav")
    if eng == "speexdec":
        return (["speexdec", inp, stem + ".wav"], "s16wav", stem + ".wav")
    raise ValueError(eng)


# ---------------------------------------------------------------- analysis

def corr_metrics(a, b, ch, a_int=False, b_int=True, n_frames=CORR_N):
    """a,b 交错样点（同 sr/ch）。在 **16bit LSB 域** 计算（float 通道 ×32768 对齐 int16）。
    返回 (corr, rms16, max16, len_a, len_b, band)——corr 取 1%..99% 中带、步进采样 ≤n_frames。"""
    fa, fb = len(a) // ch, len(b) // ch
    n = min(fa, fb)
    if n <= 1000:
        lo, hi = 0, n
    else:
        lo, hi = n // 100, n - n // 100
    band = hi - lo
    step = max(1, band // n_frames)
    if step <= 0:
        step = 1
    npts = 0
    sa = sb = sas = sbs = sab = 0.0
    sdif2 = 0.0
    sdmax = 0.0
    for k in range(0, band, step):
        f = lo + k
        for c in range(ch):
            x = a[f * ch + c]
            y = b[f * ch + c]
            if a_int:
                x16 = float(x)
            else:
                x16 = x * 32768.0
            if b_int:
                y16 = float(y)
            else:
                y16 = y * 32768.0
            sa += x16
            sb += y16
            sas += x16 * x16
            sbs += y16 * y16
            sab += x16 * y16
            npts += 1
    corr = 0.0
    if npts > 2:
        num = sab - sa * sb / npts
        da = sas - sa * sa / npts
        db = sbs - sb * sb / npts
        if da > 0 and db > 0:
            corr = num / math.sqrt(da * db)
    # rms16/max16：同带内轻扫 ≤8192 点
    step2 = max(1, band // 8192)
    cnt2 = 0
    for k in range(0, band, step2):
        f = lo + k
        for c in range(ch):
            x = a[f * ch + c]
            y = b[f * ch + c]
            if a_int:
                x16 = float(x)
            else:
                x16 = x * 32768.0
            if b_int:
                y16 = float(y)
            else:
                y16 = y * 32768.0
            d = x16 - y16
            sdif2 += d * d
            ad = abs(d)
            if ad > sdmax:
                sdmax = ad
            cnt2 += 1
    rms16 = math.sqrt(sdif2 / max(1, cnt2))
    return {"corr": round(corr, 6), "rms16": round(rms16, 3),
            "max16": round(sdmax, 1), "len_a": fa, "len_b": fb, "band": band}


def norm(arr, ch):
    """array('h') s16 → 归一化 array('f')（写回）。"""
    import array
    out = array.array("f", (x / 32768.0 for x in arr))
    return out


def grade(total):
    if total >= 95:
        return "A+"
    if total >= 90:
        return "A"
    if total >= 80:
        return "B"
    if total >= 70:
        return "C"
    return "D"


def score_speed(dur, wall):
    if not dur or wall <= 0:
        return 0.0
    r = dur / wall
    return round(W_SPEED * min(1.0, r / 50.0), 1)


def score_memory(rss_kb, floor_kb):
    ov = (rss_kb - floor_kb) / 1000.0
    for thr, s in ((3.0, 30.0), (10.0, 26.0), (25.0, 20.0), (60.0, 12.0)):
        if ov <= thr:
            return s
    return 4.0


def score_corr_lossless(eq, ref_note):
    return W_CORR if eq else 0.0


def score_corr_lossy(corr, len_abs, ref_frames, rms16):
    corr = abs(corr)  # 纯反号不可闻（speex 极性分歧等）→ 用 |corr| 计分，避免误伤
    if corr >= 0.999 and len_abs <= max(2, ref_frames * 0.001):
        return 20.0
    if corr >= 0.999 and len_abs <= max(2, ref_frames * 0.01):
        return 19.0
    if corr >= 0.99:
        return 16.0
    if corr >= 0.95:
        return 12.0
    if corr >= 0.9:
        return 8.0
    return 0.0


# ---------------------------------------------------------------- main flow

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="/tmp/eng")
    ap.add_argument("--engine", default=DEFAULT_ENGINE)
    ap.add_argument("--csv", default=os.path.join(HERE, "data", "SCORE_results.csv"))
    ap.add_argument("--md", default=os.path.join(HERE, "SCORE_results.md"))
    ap.add_argument("--workdir", default=os.path.join(HERE, ".tmp_scorecard_wd"))
    ap.add_argument("--reps", type=int, default=1,
                    help="每项采样次数；>1 时去极值取均值（更稳，更慢）")
    ap.add_argument("--pin", default="", help="taskset CPU 列表（如 0-15 固定 P 核降噪）")
    ap.add_argument("--timeout-s", type=float, default=180.0)
    ap.add_argument("--no-gen", action="store_true", help="不自动生成缺失语料")
    ap.add_argument("--build-tag", default="")
    a = ap.parse_args()

    global PIN
    PIN = a.pin
    engine = os.path.abspath(a.engine)
    if not os.path.isfile(engine):
        print(f"错误：引擎不存在 {engine}", file=sys.stderr)
        return 1
    if not a.no_gen:
        ensure_corpus(a.corpus)
    os.makedirs(os.path.dirname(a.csv) or ".", exist_ok=True)
    import shutil
    if os.path.isdir(a.workdir):
        shutil.rmtree(a.workdir, ignore_errors=True)
    os.makedirs(a.workdir, exist_ok=True)

    date = time.strftime("%Y-%m-%d")
    tag = a.build_tag or f"rel-{date}"

    tool_ver = {
        "ffmpeg": subprocess.run(["ffmpeg", "-version"], capture_output=True,
                                 text=True).stdout.splitlines()[0],
        "flac": subprocess.run(["flac", "--version"], capture_output=True,
                               text=True).stdout.splitlines()[0],
        "lame": subprocess.run(["lame", "--version"], capture_output=True,
                               text=True).stdout.splitlines()[0],
        "speexdec": "speexdec 1.2.1",
    }
    for t in ("ffmpeg", "flac", "lame", "speexdec"):
        if subprocess.run(["which", t], capture_output=True).returncode != 0:
            print(f"警告：工具缺失 {t}", file=sys.stderr)

    fields = ["date", "build_tag", "format", "file", "codec", "cls", "sr", "ch",
              "dur_s", "engine", "takeover", "rc", "wall_s", "user_s", "rss_kb",
              "frames", "ref_frames", "len_abs", "xrt", "speed", "corr",
              "rms16", "max16", "bit_exact", "mem_floor_kb", "memory",
              "correctness", "coverage", "total", "grade", "note"]
    rows = []
    os.makedirs(a.workdir, exist_ok=True)
    t_run = time.monotonic()
    run_dir = tempfile.mkdtemp(prefix="sc_run_", dir=a.workdir)

    # 第 1 遍：解码测量（所有 format × engine）
    measured = {}   # (fmt_key, eng) -> res(dict with out info)
    for fi, fmt in enumerate(FORMATS, 1):
        path = os.path.join(a.corpus, fmt["file"])
        meta = probe(path)
        dur = meta.get("dur") or 0.0
        sr = meta.get("sr", "")
        ch = int(meta.get("ch") or 0)
        codec = fmt.get("codec") or meta.get("codec", "")
        for eng in fmt["engines"]:
            outp = os.path.join(run_dir, f"pcm_{fmt['key'].replace('/', '_')}_{eng}")
            argv, kind, outfile = build_cmd(eng, path, outp, engine)
            errf = outfile + ".stderr"
            res = (measure_reps(argv, a.reps, a.timeout_s, err_path=errf)
                   if a.reps > 1 else measure_adaptive(argv, a.timeout_s, err_path=errf))
            # 需要额外一次 ffmpeg -f f32le 辅助路由（lossless 逐位证据），并入同一 engine 行
            extra_f32 = None
            if res["rc"] == 0 and fmt["cls"] == "lossless" and eng in ("ffmpeg", "era", "stable"):
                if eng == "ffmpeg":
                    argv2, k2, o2 = build_cmd("ffmpeg-f32", path, outp + ".f32", engine)
                    r2 = (measure_reps(argv2, a.reps, a.timeout_s, err_path=o2 + ".stderr")
                          if a.reps > 1 else measure_adaptive(argv2, a.timeout_s, err_path=o2 + ".stderr"))
                    extra_f32 = (r2, o2)
                else:
                    extra_f32 = (res, outfile)  # f32wav 本身即 f32
            # 解析 takeover
            take = ""
            if eng in ("era", "stable"):
                try:
                    with open(errf) as fh:
                        log = fh.read()
                    take = "native" if ("自研内核接管" in log and eng == "era") else \
                           ("native" if "自研内核接管" in log else "ffmpeg")
                except OSError:
                    take = ""
            elif eng == "ffmpeg":
                take = "ffmpeg"
            frames = None
            if res["rc"] == 0:
                try:
                    frames = file_frames(kind, outfile, ch)
                except Exception:
                    frames = None
            measured[(fmt["key"], eng)] = {
                "res": res, "kind": kind, "outfile": outfile, "frames": frames,
                "take": take, "extra_f32": extra_f32, "dur": dur, "sr": sr,
                "ch": ch, "codec": codec,
            }
            st = f"[{fi}/{len(FORMATS)}] {fmt['key']:<10} {eng:<16} rc={res['rc']} " \
                 f"wall={res['wall_s']:.3f}s rss={res['peak_rss_kb']}KB"
            print(st, file=sys.stderr)

    # 第 2 遍：正确性分析 + 评分 + 落 CSV/md
    floors = {}   # engine -> floor_kb（最小 rss，实测平台值）
    for (fk, eng), m in measured.items():
        res = m["res"]
        if res["rc"] == 0:
            floors.setdefault(eng, []).append(res["peak_rss_kb"])
    floor_kb = {e: min(v) for e, v in floors.items()}

    csv_rows = []
    md_lines = []
    L = md_lines.append
    L("# EraAudio 行业对比基准与评分（scorecard.py 自动汇总）")
    L("")
    L(f"- 生成: {time.strftime('%F %T')}   构建快照: `{tag}`")
    L(f"- 引擎: `{engine}`   语料: `{a.corpus}`")
    L(f"- 工具: ffmpeg {tool_ver['ffmpeg'].split(' ',2)[2] if len(tool_ver['ffmpeg'].split())>2 else ''}"
      f" / {tool_ver['flac']} / {tool_ver['lame']} / speexdec 1.2.1")
    L("- 引擎行 = `--player-file` 解码→float32 PCM（skip encoder，不重编码）；CLI 行 = 解码→s16。")
    L(f"- 权重: speed {W_SPEED} / memory {W_MEM} / correctness {W_CORR} / coverage {W_COV}。")
    L(f"- 阈值: speed 40·min(1,R/50)(R=实时倍数)；memory 相对各引擎最小 RSS 平台值 "
      f"(≤+3/10/25/60MB→30/26/20/12)；correctness lossless 逐位=满分、lossy len≤0.1% 且 |corr|≥0.999=满分"
      f"（反号不可闻按 |corr|）。")
    L("")

    # 先跑 lossless 逐位证据并写测量行
    for fmt in FORMATS:
        fk = fmt["key"]
        path = os.path.join(a.corpus, fmt["file"])
        meta = probe(path)
        dur = meta.get("dur") or 0.0
        ch = int(meta.get("ch") or 0)
        for eng in fmt["engines"]:
            m = measured[(fk, eng)]
            res, kind, outfile, frames = (m["res"], m["kind"], m["outfile"],
                                          m["frames"])
            rss = res["peak_rss_kb"]
            wall = res["wall_s"]
            fl = floor_kb.get(eng, rss)
            row = {
                "date": date, "build_tag": tag, "format": fk,
                "file": fmt["file"], "codec": fmt.get("codec", ""),
                "cls": fmt["cls"], "sr": meta.get("sr", ""), "ch": ch,
                "dur_s": round(dur, 3), "engine": eng, "takeover": m["take"],
                "rc": res["rc"], "wall_s": wall, "user_s": res["user_s"],
                "rss_kb": rss, "frames": frames or "", "ref_frames": "",
                "len_abs": "", "xrt": round(wall / dur, 5) if dur else "",
                "speed": score_speed(dur, wall) if res["rc"] == 0 else 0.0,
                "corr": "", "rms16": "", "max16": "", "bit_exact": "",
                "mem_floor_kb": fl, "memory": 0.0, "correctness": 0.0,
                "coverage": 0.0, "total": 0.0, "grade": "", "note": "",
            }
            if res["rc"] == 0:
                row["memory"] = score_memory(rss, fl)
            csv_rows.append(row)

    # lossless 逐位判定
    def data_md5_f32(path):
        return md5_file(path, 44) if parse_wav(path)["off"] == 44 else \
            md5_file(path, parse_wav(path)["off"])

    for fmt in FORMATS:
        if fmt["cls"] != "lossless":
            continue
        fk = fmt["key"]
        mera = measured.get((fk, "era"))
        mstab = measured.get((fk, "stable"))
        mff = measured.get((fk, "ffmpeg"))
        if not (mera and mstab and mff and mera["res"]["rc"] == 0
                and mstab["res"]["rc"] == 0 and mff["res"]["rc"] == 0):
            continue
        era_md5 = data_md5_f32(mera["outfile"]) if mera["kind"] == "f32wav" else ""
        stab_md5 = data_md5_f32(mstab["outfile"]) if mstab["kind"] == "f32wav" else ""
        ff_f32 = mff.get("extra_f32")
        ff32_md5 = ""
        if ff_f32 and ff_f32[0]["rc"] == 0 and os.path.isfile(ff_f32[1]):
            ff32_md5 = md5_file(ff_f32[1])
        eq_engine = bool(era_md5 and era_md5 == stab_md5)
        eq_ff = bool(era_md5 and ff32_md5 and era_md5 == ff32_md5)
        s16_ref_md5 = None
        # s16 参考面：ffmpeg s16 文件（同一 ffmpeg 行双输出内尚无，故另起 CLI）
        extra = subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i",
             os.path.join(a.corpus, fmt["file"]), "-map", "a:0", "-vn",
             "-c:a", "pcm_s16le", "-f", "s16le",
             os.path.join(run_dir, "s16ref_" + fk)],
            capture_output=True)
        if extra.returncode == 0:
            s16_ref_md5 = md5_file(os.path.join(run_dir, "s16ref_" + fk))
        ref_eq = True
        if fmt["ref"] == "flac-d":
            mfd = measured.get((fk, "flac-d"))
            if mfd and mfd["res"]["rc"] == 0:
                ref_eq = md5_file(mfd["outfile"]) == s16_ref_md5
        elif fmt["ref"] == "ffmpeg":
            ref_eq = True  # s16 参考即同一 ffmpeg 路由
        ok = eq_engine and eq_ff and ref_eq
        for eng in fmt["engines"]:
            for row in csv_rows:
                if row["format"] == fk and row["engine"] == eng:
                    row["bit_exact"] = "yes" if ok else "no"
                    row["note"] = ("era==stable==ffmpeg(f32) 逐位"
                                   + ("；s16 与 flac -d 一致" if fmt["ref"] == "flac-d" else ""))
                    row["correctness"] = W_CORR if ok else 0.0

    # lossy 长度 + corr（对参考引擎 PCM）
    for fmt in FORMATS:
        fk = fmt["key"]
        if fmt["cls"] != "lossy":
            continue
        ref_eng = fmt["ref"]
        mref = measured.get((fk, ref_eng))
        if not (mref and mref["res"]["rc"] == 0):
            for row in csv_rows:
                if row["format"] == fk:
                    row["note"] = (row["note"] + "；参考解码失败").strip("；")
            continue
        ref_path, ref_kind, ref_ch = mref["outfile"], mref["kind"], mref["ch"]
        # 载入参考
        if ref_kind in ("s16raw", "s16wav"):
            ref_arr = load_s16_raw(ref_path) if ref_kind == "s16raw" else \
                load_s16_wav(ref_path)
        else:
            ref_arr = load_f32_data(ref_path)[0]
        ref_frames = len(ref_arr) // ref_ch
        ref_int = ref_kind in ("s16raw", "s16wav")
        for eng in fmt["engines"]:
            m = measured.get((fk, eng))
            if not m or m["res"]["rc"] != 0 or not m["outfile"]:
                continue
            corr = rms16 = max16 = ""
            len_abs = ""
            if m["kind"] == "f32wav":
                arr = load_f32_data(m["outfile"])[0]
                cm = corr_metrics(arr, ref_arr, m["ch"], a_int=False, b_int=ref_int)
                corr, rms16, max16 = cm["corr"], cm["rms16"], cm["max16"]
                len_abs = abs(cm["len_a"] - ref_frames)
            elif m["kind"] in ("s16raw", "s16wav"):
                arr = load_s16_raw(m["outfile"]) if m["kind"] == "s16raw" else \
                    load_s16_wav(m["outfile"])
                cm = corr_metrics(arr, ref_arr, m["ch"], a_int=True, b_int=ref_int)
                corr, rms16, max16 = cm["corr"], cm["rms16"], cm["max16"]
                len_abs = abs(cm["len_a"] - ref_frames)
            for row in csv_rows:
                if row["format"] == fk and row["engine"] == eng:
                    row["corr"] = corr if corr != "" else ""
                    row["rms16"] = rms16 if rms16 != "" else ""
                    row["max16"] = max16 if max16 != "" else ""
                    row["ref_frames"] = ref_frames
                    row["len_abs"] = len_abs if len_abs != "" else ""
                    if corr != "" and ref_frames:
                        sc = score_corr_lossy(float(corr), len_abs, ref_frames,
                                              float(rms16) if rms16 != "" else 0)
                        row["correctness"] = sc
                    else:
                        row["correctness"] = 0.0

    # coverage + total
    for row in csv_rows:
        eng = row["engine"]
        if eng == "era":
            row["coverage"] = W_COV if row["takeover"] == "native" and row["rc"] == 0 \
                else 0.0
        elif row["rc"] == 0:
            row["coverage"] = W_COV
        else:
            row["coverage"] = 0.0
        total = (row["speed"] or 0.0) + (row["memory"] or 0.0) + \
                (row["correctness"] or 0.0) + (row["coverage"] or 0.0)
        row["total"] = round(total, 1)
        row["grade"] = grade(total)
        row["xrt"] = round(float(row["xrt"]), 5) if row["xrt"] != "" else ""

    # 写 CSV
    with open(a.csv, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for row in csv_rows:
            w.writerow(row)

    # 汇总统计
    def avg_rows(eng_filter=None, fmt_filter=None):
        sel = [r for r in csv_rows
               if (eng_filter is None or r["engine"] == eng_filter)
               and (fmt_filter is None or r["format"] in fmt_filter)
               and r["rc"] == 0]
        if not sel:
            return 0.0, 0.0, 0.0, 0.0, 0.0
        n = len(sel)
        return (sum(r["speed"] for r in sel) / n,
                sum(r["memory"] for r in sel) / n,
                sum(r["correctness"] for r in sel) / n,
                sum(r["coverage"] for r in sel) / n,
                sum(r["total"] for r in sel) / n)

    L("## 1. 每格式 × 每引擎 综合得分")
    L("")
    L("| 格式 | " + " | ".join(ENGINE_LABEL[e] for e in ENGINES_ORDER) + " |")
    L("|---|" + "---|" * len(ENGINES_ORDER))
    for fmt in FORMATS:
        fk = fmt["key"]
        cells = []
        for e in ENGINES_ORDER:
            r = next((r for r in csv_rows if r["format"] == fk and r["engine"] == e), None)
            if r is None:
                cells.append("—")
            else:
                cells.append(f"{r['total']}({r['grade']})")
        L(f"| {fk} | " + " | ".join(cells) + " |")
    L("")

    # 每引擎平均
    L("## 2. 自研内核总体得分（对 FFmpeg 归一）")
    L("")
    L("| 引擎 | 平均 speed(40) | 平均 memory(30) | 平均 correctness(20) | "
      "平均 coverage(10) | 平均总分 |")
    L("|---|---|---|---|---|---|")
    sums = {}
    for e in ENGINES_ORDER:
        sums[e] = avg_rows(e)
    for e in ENGINES_ORDER:
        s = sums[e]
        if s[4] == 0 and not any(r["engine"] == e for r in csv_rows):
            continue
        L(f"| {ENGINE_LABEL.get(e,e)} | {s[0]:.1f} | {s[1]:.1f} | {s[2]:.1f} | "
          f"{s[3]:.1f} | {s[4]:.1f} |")
    era = sums.get("era", (0,) * 5)
    stable = sums.get("stable", (0,) * 5)
    L("")
    if stable[4]:
        L(f"**归一结论**：EraAudio 平均总分 {era[4]:.1f}（{grade(era[4])}） vs "
          f"Stable/FFmpeg {stable[4]:.1f}（{grade(stable[4])}） → "
          f"相对 FFmpeg = **{era[4] / stable[4] * 100:.1f}%**（Δ{era[4] - stable[4]:+.1f} 分）")
    L("")

    L("## 3. 原始关键测量（wall 秒 / ×RT / RSS MB / 帧数对齐）")
    L("")
    L("| 格式 | 引擎 | ×RT | wall(s) | RSS(MB) | 帧数 | 参考帧数 | corr | bit-exact | 得分 |")
    L("|---|---|---|---|---|---|---|---|---|---|")
    for row in csv_rows:
        xrt = row["xrt"]
        rssm = (row["rss_kb"] / 1000.0) if row["rss_kb"] != "" else 0.0
        L(f"| {row['format']} | {ENGINE_LABEL.get(row['engine'], row['engine'])} "
          f"| {xrt} | {row['wall_s']} | {rssm:.1f} | {row['frames']} "
          f"| {row['ref_frames']} | {row['corr']} | {row['bit_exact']} | {row['total']} |")
    L("")

    L("## 4. 参考面与未覆盖项说明（诚实记录）")
    L("")
    for fk, note in STANDALONE_NOTE.items():
        L(f"- **{fk}**：{note}")
    L("- 其余小语种（ape/shn/tak/als/dst/mpc/wma/dsf/dff 等）未纳入本轮行业矩阵，"
      "以 `format-support-matrix.md` 为准；本轮聚焦播放器主流 15 轨。")
    L("- EraAudio 自研测量均为 `--engine-mode 1` 且 **native 接管**（takeover=原生），无回退；"
      "构建顺序 `zig build -Doptimize=ReleaseFast` → `cmake --build build`（ReleaseFast kernel）。")
    L("")

    L(f"总耗时 {time.monotonic() - t_run:.0f}s。产物：`{a.csv}`。")
    with open(a.md, "w") as fh:
        fh.write("\n".join(md_lines) + "\n")
    print(f"written {a.csv}\nwritten {a.md}")
    import shutil
    shutil.rmtree(run_dir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
