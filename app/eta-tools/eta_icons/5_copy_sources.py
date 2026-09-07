#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# eta_icons 归档校验器：检查 app/eta-tools/eta_icons/source/（入库定稿子集）是否覆盖
# registry.json 全部字形（regular/filled/added 双侧）。
#
# 说明：源素材全集(Icon化)为本地参考且已 gitignore 删除；入库的只有本 source/
# 定稿子集与最终字体。新增字形需先在 source/ 补入对应 regular/filled SVG。
# 用法：python3 app/eta-tools/eta_icons/5_copy_sources.py
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
registry = json.load(open(os.path.join(HERE, 'src', 'registry.json'), encoding='utf-8'))
SRC = os.path.join(HERE, 'source')

missing = []
for name, u in registry['glyphs'].items():
    sub = 'added' if u['kind'] == 'added' else ('filled' if u['style'] == 'filled' else 'regular')
    p = os.path.join(SRC, sub, f"{u['glyph']}.svg")
    if not os.path.exists(p):
        missing.append(f'{name} <- source/{sub}/{u["glyph"]}.svg')

if missing:
    print(f'!! 归档缺失 {len(missing)} 个字形源:')
    for m in missing:
        print('  ', m)
    raise SystemExit(1)
print(f'归档完整: source/ 覆盖 registry 全部 {len(registry["glyphs"])} 字形 ✓')
