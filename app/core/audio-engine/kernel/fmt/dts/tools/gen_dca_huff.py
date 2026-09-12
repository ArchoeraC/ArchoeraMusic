#!/usr/bin/env python3
import re
from pathlib import Path

# 仓库根下的 reference/FFmpeg（可用 ARCHOERA_FFMPEG_SRC 覆盖）
_REPO = Path(__file__).resolve().parents[7]
SRC = str(_REPO / "reference" / "FFmpeg" / "libavcodec")

def strip_comments(text):
    return re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)

def find_body(text, name):
    m = re.search(r'\b' + name + r'\b[^=]*=', text)
    i = text.index('{', m.end()); depth=0
    for j in range(i, len(text)):
        c = text[j]
        if c=='{': depth+=1
        elif c=='}':
            depth-=1
            if depth==0: return text[i+1:j]

txt = strip_comments(open(SRC+"/dcahuff.c").read())

# scalar consts
sizes = [int(x) for x in re.findall(r'-?[0-9]+', find_body(txt, 'ff_dca_bitalloc_sizes'))]
offs = [int(x) for x in re.findall(r'-?[0-9]+', find_body(txt, 'ff_dca_bitalloc_offsets'))]

# pairs table
body = find_body(txt, 'ff_dca_vlc_src_tables')
pairs = [(int(a), int(b)) for a,b in re.findall(r'\{\s*(-?[0-9]+)\s*,\s*([0-9]+)\s*\}', body)]

group_size = [1,3,3,3,3,7,7,7,7,7]  # from dcadata quant_index_group_size

# slice quant tables in ffmpeg consumption order
sec = []
def emit(name, rows):
    sec.append((name, rows))

for i in range(10):
    for j in range(group_size[i]):
        emit(f"quant_{i}_{j}", pairs[:sizes[i]]); del pairs[:sizes[i]]
for j in range(5):
    emit(f"bitalloc_{j}", pairs[:12]); del pairs[:12]
for j in range(5):
    emit(f"scalef_{j}", pairs[:129]); del pairs[:129]
for j in range(4):
    emit(f"tmode_{j}", pairs[:4]); del pairs[:4]

# remaining pairs are LBR tables - not needed for core

out = []
out.append("//! Generated: quant/bitalloc/scalef/tmode huffman code sections (symbol,len).")
for name, rows in sec:
    syms = ",".join(str(a) for a,_ in rows)
    lens = ",".join(str(b) for _,b in rows)
    out.append(f"pub const {name}_sym = [_]i16{{ {syms} }};")
    out.append(f"pub const {name}_len = [_]u8{{ {lens} }};")
out.append(f"pub const bitalloc_sizes = [_]u8{{ {','.join(map(str,sizes))} }};")
out.append(f"pub const bitalloc_offsets = [_]i16{{ {','.join(map(str,offs))} }};")
open("/tmp/opencode/huff_sections.zig","w").write("\n".join(out)+"\n")
print("ok sections:", len(sec), "core total entries:", sum(len(r) for _,r in sec))
