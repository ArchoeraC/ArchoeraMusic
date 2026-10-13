#!/usr/bin/env python3
# ArchoeraMusic
# Copyright (C) 2026 Archoera && BetaStudio2
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 本地曲库搜索索引：Unicode 兼容折叠 / 释义查询扩展数据表生成脚本（离线、确定、可重跑）。
#
# 背景（方向 A 重构，2026-10）：索引侧不再自带以下数据表 / 外部依赖，改由外部库与框架提供：
#   - 拼音（含词级多音字消歧）/ 繁转简 / 全角半角 → ToolGood.Words（Apache-2.0，NuGet 依赖）；
#   - GB18030 / GBK 解码 → .NET 框架内置 CodePagesEncodingProvider；
#   - 英文残留阻断表 → 已删除。
# 本脚本生成两张表：
#   1. NFKC 兼容折叠表（ToolGood.Words 不折叠 ﬁ / ① 等兼容字）；
#   2. Unihan 释义查询扩展表（T1：英文 ↔ 汉字释义，供查询侧跨语言候选分支，不改索引侧）。
#
# 输出（带 '#' 注释头，HanziData 解析时跳过）：
#   data/nfkc.tsv         HEXCODE<TAB>HEXOUT1 HEXOUT2 ...（输入/输出均为码点十六进制、空格分隔）
#   data/def_en2hanzi.tsv WORD<TAB>HEX1 HEX2 ...（英文词 → 候选汉字码点，去重、按码点序、≤ 8）
#   data/def_hanzi2en.tsv HEXCODE<TAB>WORD1 WORD2 ...（汉字码点 → 英文词，去重、字典序）
#
# 许可：nfkc.tsv 派生自 Python 标准库 unicodedata（Unicode License）；
#   def_*.tsv 派生自 Unicode Unihan 数据库 kDefinition 字段（Unicode License）。
#   详见同目录 THIRD-PARTY-LICENSES.md。
#
# 输入：nfkc 无需外部输入；defs 需要 reference/unihan/Unihan.zip（仓库级 .gitignore 忽略）。
#   缺失时用宿主机代理（http_proxy / https_proxy 环境变量）从 unicode.org 下载到
#   reference/unihan/，保证可重跑；离线且缺失则明确报错退出。
import os
import re
import sys
import unicodedata
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]               # 仓库根
OUT = Path(__file__).resolve().parents[1] / "data"       # app/core/indexer/data
UNIHAN_DIR = ROOT / "reference" / "unihan"
UNIHAN_ZIP = UNIHAN_DIR / "Unihan.zip"
UNIHAN_URL = "https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip"

# 每个英文词最多保留的候选汉字数（查询侧 OR 分支预算的一部分）。
EN2HANZI_MAX = 8

# 英文停用词表（内置小表）：仅过滤释义里几乎无区分度的功能词与词典套话，
# 保留 like / love / big 等实义词。可在报告里完整列出。
STOPWORDS = frozenset(
    """
    a an the this that these those
    of to and or but nor so as at by for from in into onto on with without
    is are was were be been being am do does did done
    it its he she they them their his her hers him his we us our you your i me my mine
    one two three four five six seven eight nine ten
    used use using also same very more most much many
    variant variants form forms old ancient name names surname clan river
    non japanese chinese korean cantonese mandarin
    etc ie eg abbreviation
    """.split()
)

_WORD_RE = re.compile(r"[a-z][a-z'\-]+")
_PAREN_RE = re.compile(r"\([^)]*\)|\[[^\]]*\]")


def gen_nfkc() -> list[tuple[int, str]]:
    """逐字符 NFKC 兼容折叠表（全范围，逐字符应用）。

    遍历 U+0000..U+10FFFF（跳过代理区 U+D800..U+DFFF），取
    `unicodedata.normalize('NFKC', chr(cp))`；仅当结果 ≠ 原字符时记一行。
    键为**码点**十六进制；值为**码点序列**（十六进制、空格分隔，非 BMP 为 5/6 位）。
    归一结果含控制符 / TAB / 换行时**跳过**（保持原字符，保证单行可解析）。

    近似：**逐字符**应用——跨字符规范化组合（base + combining 合成）不在此表覆盖范围。
    """
    rows: list[tuple[int, str]] = []
    for cp in range(0x110000):
        if 0xD800 <= cp <= 0xDFFF:  # 代理区不构成独立字符
            continue
        ch = chr(cp)
        folded = unicodedata.normalize("NFKC", ch)
        if folded == ch:
            continue
        if any(ord(c) < 0x20 or c in "\t\n\r" for c in folded):
            continue
        rows.append((cp, " ".join(f"{ord(c):04X}" for c in folded)))
    return rows


def ensure_unihan() -> Path:
    """返回 Unihan.zip 路径；缺失时经宿主机代理下载到 reference/unihan/。"""
    if UNIHAN_ZIP.exists():
        return UNIHAN_ZIP
    UNIHAN_DIR.mkdir(parents=True, exist_ok=True)
    proxy = os.environ.get("https_proxy") or os.environ.get("http_proxy")
    handlers = (
        [urllib.request.ProxyHandler({"http": proxy, "https": proxy})] if proxy else []
    )
    opener = urllib.request.build_opener(*handlers)
    part = UNIHAN_ZIP.with_name("Unihan.zip.part")
    print(f"==> 下载 Unihan.zip → {UNIHAN_ZIP}（proxy={proxy or 'none'}）")
    try:
        with opener.open(UNIHAN_URL, timeout=180) as resp, part.open("wb") as fh:
            while True:
                chunk = resp.read(1 << 20)
                if not chunk:
                    break
                fh.write(chunk)
    except Exception as exc:  # 网络失败 → 明确报错，保留已存在的旧压缩包（若有）
        if part.exists():
            part.unlink()
        raise SystemExit(
            f"无法获取 Unihan.zip（{exc}）；请手动放置到 {UNIHAN_ZIP} 后重跑。"
        )
    part.replace(UNIHAN_ZIP)
    return UNIHAN_ZIP


def parse_definition(value: str) -> set[str]:
    """Unihan kDefinition 值 → 规范英文词集合。

    步骤：去 (...) / [...] 括注 → 小写 → 按词形切分（`[a-z][a-z'-]+`）→ 去尾部
    连字符 / 撇号 → 过滤停用词与长度 < 2 的词。
    """
    cleaned = _PAREN_RE.sub(" ", value).lower()
    words: set[str] = set()
    for match in _WORD_RE.finditer(cleaned):
        word = match.group(0).rstrip("'-")
        if len(word) >= 2 and word not in STOPWORDS:
            words.add(word)
    return words


def gen_hanzi_defs(zip_path: Path) -> tuple[dict[str, list[int]], dict[int, list[str]]]:
    """解析 Unihan_Readings.txt 的 kDefinition，生成双向释义表。

    - hanzi2en：码点 → 有序英文词列表；
    - en2hanzi：英文词 → 候选码点列表（按「主区优先、码点升序」排序，去重、≤ EN2HANZI_MAX）。
    """
    hanzi2en: dict[int, list[str]] = {}
    with zipfile.ZipFile(zip_path) as archive, archive.open("Unihan_Readings.txt") as raw:
        for line in raw:
            text = line.decode("utf-8").rstrip("\n")
            if not text or text.startswith("#"):
                continue
            cols = text.split("\t")
            if len(cols) != 3 or cols[1] != "kDefinition":
                continue
            token = cols[0]
            if not token.startswith("U+"):
                continue
            try:
                cp = int(token[2:], 16)
            except ValueError:
                continue
            words = parse_definition(cols[2])
            if words:
                hanzi2en[cp] = sorted(words)

    en2hanzi: dict[str, list[int]] = {}
    for cp, words in hanzi2en.items():
        for word in words:
            en2hanzi.setdefault(word, []).append(cp)

    def rank(cp: int) -> tuple[int, int]:
        # 优先 CJK 统一表意主区（U+4E00–U+9FFF，常用字），其余（扩展区 / 兼容区）排后；
        # 同级按码点升序，保证确定、可重跑。
        return (0 if 0x4E00 <= cp <= 0x9FFF else 1, cp)

    for word in en2hanzi:
        en2hanzi[word] = sorted(set(en2hanzi[word]), key=rank)[:EN2HANZI_MAX]
    return en2hanzi, hanzi2en


def write_table(path: Path, header: list[str], rows: list[tuple[int, str]]) -> None:
    lines = [f"# {h}" for h in header]
    for a, b in rows:
        lines.append(f"{a:04X}\t{b}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)

    nfkc = gen_nfkc()
    write_table(
        OUT / "nfkc.tsv",
        [
            "Archoera indexer 逐字符 NFKC 兼容折叠表（生成，勿手改）",
            f"来源: Python unicodedata.normalize('NFKC', chr(cp))（Unicode {unicodedata.unidata_version}）",
            "字段: HEXCODE<TAB>HEXOUT1 HEXOUT2 ...；输入/输出均为码点十六进制、空格分隔",
            "生成: tools/gen_hanzi_data.py（离线、确定、遍历 U+0000..U+10FFFF，仅当归一结果≠原字符）",
            "近似: 逐字符应用；跨字符规范化组合（base+combining 合成）不覆盖",
            "跳过: 代理区 U+D800..U+DFFF；归一结果含控制符 / TAB / 换行 的码点",
        ],
        nfkc,
    )

    zip_path = ensure_unihan()
    en2hanzi, hanzi2en = gen_hanzi_defs(zip_path)
    # en2hanzi 的键是字符串（英文词），用专用写出；hanzi2en 的键是码点，复用 write_table。
    _write_en2hanzi(OUT / "def_en2hanzi.tsv", en2hanzi)
    # hanzi2en 的值为词列表：写出前空格连接为单字段（与注释头 HEXCODE<TAB>WORD1 WORD2 …
    # 一致）。**不可**把 list 直接交给 write_table——那会写成 Python repr（历史 bug）。
    write_table(
        OUT / "def_hanzi2en.tsv",
        [
            "Archoera indexer Unihan 释义查询扩展：汉字码点 → 英文词列表（T1，查询侧用）",
            "来源: Unicode Unihan kDefinition（Unicode License，https://www.unicode.org/license.txt）",
            "字段: HEXCODE<TAB>WORD1 WORD2 ...；WORD 去重、字典序",
            "生成: tools/gen_hanzi_data.py gen_hanzi_defs()（去括注/小写/停用词过滤，确定可重跑）",
        ],
        [(cp, " ".join(words)) for cp, words in sorted(hanzi2en.items())],
    )

    print(f"nfkc.tsv         : {len(nfkc)} 条")
    print(f"def_en2hanzi.tsv : {len(en2hanzi)} 词，候选码点共 {sum(len(v) for v in en2hanzi.values())}")
    print(f"def_hanzi2en.tsv : {len(hanzi2en)} 字")
    return 0


def _write_en2hanzi(path: Path, table: dict[str, list[int]]) -> None:
    header = [
        "Archoera indexer Unihan 释义查询扩展：英文词 → 候选汉字码点（T1，查询侧用）",
        "来源: Unicode Unihan kDefinition（Unicode License，https://www.unicode.org/license.txt）",
        f"字段: WORD<TAB>HEX1 HEX2 ...；HEX 为汉字码点（去重、主区优先+码点升序、每词 ≤ {EN2HANZI_MAX}）",
        "生成: tools/gen_hanzi_data.py gen_hanzi_defs()（去括注/小写/停用词过滤，确定可重跑）",
    ]
    lines = [f"# {h}" for h in header]
    for word in sorted(table):
        cps = " ".join(f"{cp:04X}" for cp in table[word])
        lines.append(f"{word}\t{cps}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
