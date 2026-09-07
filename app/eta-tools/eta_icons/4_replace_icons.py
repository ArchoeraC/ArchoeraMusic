#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 app/lib 下 Icons.<material> 引用全局替换为 EtaIcons.<const>，
并为用到 EtaIcons 的文件补 import。
映射源：app/eta-tools/eta_icons/src/registry.json（由 0_gen_registry.py 生成）。
用法：python3 app/eta-tools/eta_icons/4_replace_icons.py [--dry-run]
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.abspath(os.path.join(HERE, '..', '..'))  # eta_icons → eta-tools → app
LIB = os.path.join(APP, 'lib')
registry = json.load(open(os.path.join(HERE, 'src', 'registry.json'), encoding='utf-8'))
MAT = registry['material']          # material_icon -> const
IMPORT = "import 'package:archoera_music/eta/icon/eta_icons.dart';"

dry = '--dry-run' in sys.argv

icon_re = re.compile(r'\bIcons\.([a-zA-Z0-9_]+)')
total_repl = 0
touched = []

for dirpath, _, files in os.walk(LIB):
    for f in files:
        if not f.endswith('.dart'):
            continue
        p = os.path.join(dirpath, f)
        txt = open(p, encoding='utf-8').read()

        def sub(m):
            global total_repl
            mat = m.group(1)
            const = MAT.get(mat)
            if const is None:
                # 保留原样（理论上不会发生；若发生说明 registry 与代码脱节）
                return m.group(0)
            total_repl += 1
            return f'EtaIcons.{const}'

        new = icon_re.sub(sub, txt)
        if new == txt:
            continue
        touched.append(p)
        if dry:
            continue
        # 补 import：插到最后一个 import 之后（若无 import 插到文件头）
        if IMPORT not in new:
            imports = [l for l in new.splitlines(keepends=True) if l.startswith('import ')]
            if imports:
                last_import_end = new.rindex(imports[-1]) + len(imports[-1])
                new = new[:last_import_end] + IMPORT + '\n' + new[last_import_end:]
            else:
                new = IMPORT + '\n\n' + new
        open(p, 'w', encoding='utf-8').write(new)

print(f'{"[dry-run] " if dry else ""}替换引用 {total_repl} 处 / 触碰文件 {len(touched)} 个')
if dry:
    for p in touched:
        print('  ', os.path.relpath(p, ROOT))
