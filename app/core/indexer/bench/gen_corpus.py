#!/usr/bin/env python3
# ArchoeraMusic
# Copyright (C) 2026 Archoera && BetaStudio2
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 本地曲库搜索索引器 P5 性能 harness —— 确定性语料 / library.db 生成器。
#
# 生成一个符合 scanner `tracks` schema（见 app/core/scanner/SqliteDirectWriter.cs）的
# 临时 `library.db`：每条曲目含 id/path/title/artists(JSON)/album(JSON)/lyrics/file_mtime。
#   - 歌词仿真实中文：2–8 KB/曲，多行、含标点、部分含英文/数字、部分繁体；
#   - 约 50% 曲目附带同名 `.lrc` 侧车（带时间轴/标签，供 --index-lrc 测试）；
#   - 全部由固定 seed 驱动：同 (--tracks,--seed) 输出内容完全一致。
#
# 依赖：仅 Python 标准库（sqlite3）。不新增任何第三方依赖。
#
# 用法：
#   python3 gen_corpus.py --out /path/to/corpus --tracks 10000 --seed 20261013
# 产物：
#   <out>/library.db            源曲库（scanner schema）
#   <out>/audio/<id>.mp3         曲目路径锚（文件本身不写出，indexer 不读音频）
#   <out>/audio/<id>.lrc         侧车歌词（约 50%，确定性）
#   <out>/corpus_manifest.json   语料统计（N / 歌词字节 / 侧车数）

from __future__ import annotations

import argparse
import json
import os
import random
import sqlite3
import sys

# ---------------------------------------------------------------------------
# 固定词表（简体）。刻意包含可被 §8 代表查询命中的词：
#   爱你 / 我爱你（pinyin wo ai ni → 首字母 wan）、love、hello。
# ---------------------------------------------------------------------------
PHRASES = [
    "夜晚", "星光", "大海", "天空", "回忆", "青春", "故事", "梦想", "城市", "雨后",
    "你的眼睛", "我的思念", "远方", "故乡", "月亮", "森林", "彩虹", "时光", "世界",
    "温柔的风", "孤单的旅人", "灿烂的夏天", "安静的街", "遥远的星河", "漫长旅途",
    "勇敢的心", "自由的鸟", "沉默的海", "温柔的你", "梦想的家", "记忆深处",
    "年少的我们", "无人的街道", "灯火通明的夜", "山与海之间", "来时的路",
]
ACTIONS = [
    "想起", "拥抱", "等待", "遗忘", "流浪", "歌唱", "跳舞", "微笑", "哭泣", "奔跑",
    "说着", "看着", "爱着", "想着", "走过", "飞过", "许下", "写下", "听见", "看见",
]
TAILS = [
    "在风里", "在梦里", "在天亮之前", "在无人的街", "在时光尽头", "在很远的地方",
    "一直到永远", "不再回头", "就这样吧", "还有你",
]
LATIN = [
    "love", "forever", "dream", "hello", "angel", "goodbye", "night", "shine",
    "fly", "me to the moon", "all we need",
]
CONN = ["，", "。", "！", "？", "、", "——", "…"]
END = ["", "。", "！", "？"]

# 繁体映射（仅用于制造繁简互通语料；indexer 索引期归一为简体）。
TRAD = str.maketrans({
    "爱": "愛", "时": "時", "梦": "夢", "国": "國", "远": "遠", "间": "間",
    "长": "長", "风": "風", "鸟": "鳥", "记": "記", "忆": "憶", "还": "還",
    "过": "過", "为": "為", "听": "聽", "见": "見", "说": "說", "来": "來",
})

# 代表查询的注入行（概率注入，避免每个查询都命中全库而失真）。
# 使每个代表词在全库中出现在一个有代表性的子集（约 6–20%），贴近真实曲库的相关度分布。
INJECT = [
    ("我爱你 中国", 0.10),
    ("我好爱你 在每一个夜里", 0.08),
    ("我愛你 時光不老", 0.06),
    ("hello 你好 世界", 0.10),
    ("love is all we need", 0.12),
]

ARTISTS = [
    "周杰伦", "邓丽君", "五月天", "陈奕迅", "王菲", "林俊杰",
    "BEYOND", "张惠妹", "许巍", "李宗盛", "孙燕姿", "朴树",
]
ALBUMS = [
    "叶惠美", "经典", "自传", "认了吧", "寓言", "第二天堂",
    "海阔天空", "阿密特", "时光漫步", "山丘", "风筝", "生如夏花",
]
TITLES = [
    "晴天", "月亮代表我的心", "倔强", "十年", "红豆", "江南", "光辉岁月",
    "听海", "蓝莲花", "爱的代价", "遇见", "平凡之路", "夜空中最亮的星",
    "匆匆那年", "海阔天空", "我愿意", "后来", "童话", "起风了", "起跑线",
]
CODECS = ["mp3", "flac", "aac", "alac", "vorbis", "opus", "wav"]


def make_line(rng: random.Random) -> str:
    """用固定词表拼一行仿真实歌词（确定性）。"""
    n = rng.randint(3, 7)
    words: list[str] = []
    for _ in range(n):
        r = rng.random()
        if r < 0.10:
            words.append(rng.choice(LATIN))
        elif r < 0.16:
            words.append(str(rng.randint(1980, 2026)))
        elif r < 0.58:
            words.append(rng.choice(PHRASES))
        elif r < 0.88:
            words.append(rng.choice(ACTIONS))
        else:
            words.append(rng.choice(TAILS))
    line = words[0]
    for w in words[1:]:
        line += rng.choice(CONN) + w
    return line + rng.choice(END)


def gen_lyrics(rng: random.Random, min_bytes: int, max_bytes: int) -> str:
    """生成 2–8 KB（字节）的多行中文歌词；代表查询词概率注入，部分行随机转繁体。"""
    target = rng.randint(min_bytes, max_bytes)
    lines = [line for line, p in INJECT if rng.random() < p]
    total = sum(len(l.encode("utf-8")) + 1 for l in lines)
    while total < target:
        line = make_line(rng)
        if rng.random() < 0.15:  # 约 15% 行转繁体，制造繁简互通
            line = line.translate(TRAD)
        lines.append(line)
        total += len(line.encode("utf-8")) + 1
    return "\n".join(lines)


def gen_lrc(rng: random.Random, lyrics: str) -> str:
    """把歌词前若干行包装成带时间轴/标签的 .lrc 侧车（LrcReader 会剥离标签）。"""
    out = ["[ti:bench]", "[by:bench]"]
    sec = 0
    for line in lyrics.split("\n")[: rng.randint(6, 14)]:
        mm, ss = divmod(sec, 60)
        out.append(f"[{mm:02d}:{ss:02d}.00]{line}")
        sec += rng.randint(3, 7)
    return "\n".join(out) + "\n"


# scanner tracks schema（逐字对齐 SqliteDirectWriter.EnsureTracksTable）。
TRACKS_SCHEMA = """
CREATE TABLE IF NOT EXISTS tracks (
    id TEXT PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    track INTEGER,
    artists TEXT NOT NULL DEFAULT '[]',
    album TEXT,
    duration INTEGER NOT NULL,
    cover TEXT,
    codec TEXT,
    sample_rate INTEGER,
    bit_rate INTEGER,
    channels INTEGER,
    bits_per_sample INTEGER,
    file_size INTEGER NOT NULL,
    file_mtime INTEGER,
    file_ctime INTEGER,
    scanned_at INTEGER NOT NULL,
    lyrics TEXT,
    loudness_lufs REAL,
    loudness_peak REAL,
    -- .lrc 侧车：**扫描器**解析写入（索引器 / 播放侧只读 DB；见 shared/lyrics/LrcReader.cs）
    lyrics_lrc TEXT,
    lyrics_lrc_trans TEXT,
    lyrics_lrc_romaji TEXT,
    lrc_mtime INTEGER,
    lrc_size INTEGER,
    lrc_checked INTEGER
);
CREATE INDEX IF NOT EXISTS idx_tracks_title ON tracks(title);
CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album);
CREATE TABLE IF NOT EXISTS _scanner_meta (generation INTEGER);
"""


def generate(out_dir: str, tracks: int, seed: int, min_kb: int, max_kb: int,
             lrc_ratio: float, generation: int) -> dict:
    audio_dir = os.path.join(out_dir, "audio")
    os.makedirs(audio_dir, exist_ok=True)
    db_path = os.path.join(out_dir, "library.db")
    if os.path.exists(db_path):
        os.remove(db_path)

    min_bytes, max_bytes = min_kb * 1024, max_kb * 1024
    rows = []
    lrc_count = 0
    total_lyrics_bytes = 0

    conn = sqlite3.connect(db_path)
    try:
        conn.executescript(TRACKS_SCHEMA)
        conn.execute("DELETE FROM _scanner_meta")
        conn.execute("INSERT INTO _scanner_meta (generation) VALUES (?)", (generation,))

        for i in range(tracks):
            rng = random.Random(seed * 1_000_003 + i)
            tid = f"t{i:07d}"
            path = os.path.join(audio_dir, f"{tid}.mp3")
            title = rng.choice(TITLES)
            artists = [{"name": rng.choice(ARTISTS)}]
            if rng.random() < 0.25:
                artists.append({"name": rng.choice(ARTISTS)})
            album = {"name": rng.choice(ALBUMS)}
            lyrics = gen_lyrics(rng, min_bytes, max_bytes)
            total_lyrics_bytes += len(lyrics.encode("utf-8"))
            mtime = 1_600_000_000_000 + i * 1000

            # 约 50% 曲目有同名侧车（确定性：由 per-track rng 决定）。
            # 侧车**内容照写文件**（贴近真实磁盘布局），但库里的 `lyrics_lrc*` 才是
            # 索引器读取的来源——扫描器就该把这些列写进去（本生成器扮演扫描器）。
            lrc_text = None
            if rng.random() < lrc_ratio:
                lrc_text = gen_lrc(rng, lyrics)
                with open(os.path.join(audio_dir, f"{tid}.lrc"), "w", encoding="utf-8") as f:
                    f.write(lrc_text)
                lrc_count += 1

            lrc_m = (mtime + 1) if lrc_text is not None else 0
            lrc_s = len(lrc_text.encode("utf-8")) if lrc_text is not None else 0
            rows.append((
                tid, path, title, rng.randint(1, 20),
                json.dumps(artists, ensure_ascii=False),
                json.dumps(album, ensure_ascii=False),
                rng.randint(120, 360),
                rng.choice(CODECS), rng.choice([44100, 48000, 96000]),
                rng.choice([128000, 192000, 320000, 1000000]),
                rng.choice([1, 2]), rng.choice([16, 24]),
                rng.randint(3_000_000, 12_000_000), mtime,
                mtime - rng.randint(0, 86_400_000), 1_700_000_000_000,
                lyrics, None, None,
                lrc_text, None, None, lrc_m, lrc_s, 1,
            ))

        conn.executemany(
            """INSERT INTO tracks
               (id, path, title, track, artists, album, duration, codec, sample_rate,
                bit_rate, channels, bits_per_sample, file_size, file_mtime, file_ctime,
                scanned_at, lyrics, loudness_lufs, loudness_peak,
                lyrics_lrc, lyrics_lrc_trans, lyrics_lrc_romaji, lrc_mtime, lrc_size, lrc_checked)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            rows,
        )
        conn.commit()
    finally:
        conn.close()

    manifest = {
        "tracks": tracks,
        "seed": seed,
        "generation": generation,
        "min_kb": min_kb,
        "max_kb": max_kb,
        "lrc_ratio": lrc_ratio,
        "lrc_count": lrc_count,
        "total_lyrics_bytes": total_lyrics_bytes,
        "avg_lyrics_bytes": round(total_lyrics_bytes / tracks, 1) if tracks else 0,
        "library_db_bytes": os.path.getsize(db_path),
        "library_db": db_path,
        "audio_dir": audio_dir,
    }
    with open(os.path.join(out_dir, "corpus_manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    return manifest


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="确定性中文歌词语料 / library.db 生成器")
    ap.add_argument("--out", required=True, help="输出目录（library.db 与 audio/ 所在）")
    ap.add_argument("--tracks", type=int, default=10000, help="曲目数 N（默认 10000）")
    ap.add_argument("--seed", type=int, default=20261013, help="确定性随机种子")
    ap.add_argument("--min-kb", type=int, default=2, help="歌词最小字节（KB）")
    ap.add_argument("--max-kb", type=int, default=8, help="歌词最大字节（KB）")
    ap.add_argument("--lrc-ratio", type=float, default=0.5, help=".lrc 侧车比例（默认 0.5）")
    ap.add_argument("--generation", type=int, default=1, help="_scanner_meta.generation")
    a = ap.parse_args(argv)

    if a.tracks <= 0:
        print("--tracks 必须为正", file=sys.stderr)
        return 2
    os.makedirs(a.out, exist_ok=True)
    m = generate(a.out, a.tracks, a.seed, a.min_kb, a.max_kb, a.lrc_ratio, a.generation)
    print(json.dumps(m, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
