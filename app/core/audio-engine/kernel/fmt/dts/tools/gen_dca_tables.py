#!/usr/bin/env python3
"""Extract numeric const arrays from FFmpeg dcadata.c / dcahuff.c -> Zig."""
import os, re, sys
from pathlib import Path

# 仓库根下的 reference/FFmpeg（可用 ARCHOERA_FFMPEG_SRC 覆盖）
_REPO = Path(__file__).resolve().parents[7]
SRC = os.environ.get(
    "ARCHOERA_FFMPEG_SRC", str(_REPO / "reference" / "FFmpeg" / "libavcodec")
)

def strip_comment_block(text):
    # remove /* ... */ comments
    return re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)

def extract_ints(cpath, name):
    text = open(cpath).read()
    text = strip_comment_block(text)
    # locate 'name' = ...
    m = re.search(r'\b' + re.escape(name) + r'\b[^=]*=', text)
    if not m:
        raise SystemExit("not found: " + name)
    # find matching braces
    i = text.index('{', m.end())
    depth = 0
    for j in range(i, len(text)):
        if text[j] == '{': depth += 1
        elif text[j] == '}':
            depth -= 1
            if depth == 0:
                end = j
                break
    body = text[i+1:end]
    toks = re.findall(r'-?[0-9]+', body)
    return [int(t) for t in toks]

def extract_rows(cpath, name, rows, cols):
    vals = extract_ints(cpath, name)
    if len(vals) != rows*cols:
        raise SystemExit(f"{name}: expected {rows*cols} got {len(vals)}")
    return vals

def main():
    cpath = SRC + "/dcadata.c"
    out = []
    def emit_const(ztype, name, rows, cols=None, perline=8):
        vals = extract_rows(cpath, name, rows, cols or 1)
        out.append(f"pub const {name}: [{ztype}; {len(vals)}] = {{")
        for i in range(0, len(vals), perline):
            chunk = vals[i:i+perline]
            out.append("    " + ", ".join(str(v) for v in chunk) + ",")
        out.append("};\n")
    # small tables
    emit_const("u8",  "ff_dca_quant_index_sel_nbits", 10)
    emit_const("u8",  "ff_dca_quant_index_group_size", 10)
    emit_const("u32", "ff_dca_scale_factor_quant6", 64, perline=8)
    emit_const("u32", "ff_dca_scale_factor_quant7", 128, perline=8)
    emit_const("u32", "ff_dca_joint_scale_factors", 129, perline=8)
    emit_const("u32", "ff_dca_scale_factor_adj", 4)
    emit_const("u32", "ff_dca_quant_levels", 32, perline=8)
    emit_const("u32", "ff_dca_lossy_quant", 32, perline=8)
    emit_const("u32", "ff_dca_lossless_quant", 32, perline=8)
    emit_const("i16", "ff_dca_adpcm_vb", 4096*4, perline=16)
    emit_const("i8",  "ff_dca_high_freq_vq", 1024*32, perline=32)
    emit_const("i32", "ff_dca_fir_32bands_perfect_fixed", 512, perline=8)
    emit_const("i32", "ff_dca_fir_32bands_nonperfect_fixed", 512, perline=8)
    emit_const("i32", "ff_dca_lfe_fir_64_fixed", 256, perline=8)
    open("/tmp/opencode/dca_tables_body.zig", "w").write("\n".join(out) + "\n")
    print("wrote", sum(1 for _ in out), "lines")

main()
