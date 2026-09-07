#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""eta_icons 权威注册表生成器（精选模式：仅保留项目实际使用字形）。

设计：
  - 命名：裸名 = 实心视觉（Material 无后缀/_filled）；`xOutline` = 描边（_outlined/_border）
  - glyph 概念名去尾序数与风格后缀（refresh_2→refresh、user_1→user）；冲突保留序数
  - 来源：mapping.csv（material→mingcute 1:1 定稿）+ EXTRA app 专用字形(miniplayer 等)
  - usage 优先扫 app/lib 的裸 Icons.*；若已 EtaIcons 化则退化为 mapping.csv 全量，保证幂等

输入：mapping.csv + app/lib 源码
输出：app/eta-tools/eta_icons/src/registry.json + eta_icons.csv
用法：python3 app/eta-tools/eta_icons/src/0_gen_registry.py
"""
import csv, json, os, re, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))  # src → eta_icons → eta-tools → app → 仓库根
MAPPING_CSV = os.path.join(ROOT, 'Icon化', 'ArchoeraMusic-mingcute-icons', 'icons-mingcute', 'mapping.csv')
LIB = os.path.join(ROOT, 'app', 'lib')

# ---------- material → (kind, glyph) 映射 ----------
rows = list(csv.DictReader(open(MAPPING_CSV, encoding='utf-8')))
mat_glyph = {}
for r in rows:
    m = r['material_icon'].strip()
    p = r['primary'].strip()
    kind = 'added' if p.startswith('added:') else 'mc'
    mat_glyph[m] = {
        'kind': kind,
        'glyph': p.split(':', 1)[1] if kind == 'added' else p,
        'uses': int(r['uses'].strip() or 0),
    }


def style_of(mat):
    """按 Material 自身风格归类：描边视觉(_outlined/_outline/_border) → regular；其余 → filled"""
    if mat.endswith(('_outlined', '_outline', '_border')):
        return 'regular'
    return 'filled'


def clean_glyph(g):
    """glyph 概念清理：去 trailing 风格后缀 与 序数。"""
    c = re.sub(r'_(outlined|outline|filled|border)$', '', g)
    c = re.sub(r'_\d+$', '', c)
    return c


def snake_to_camel(s):
    return s.split('_')[0] + ''.join(p.capitalize() for p in s.split('_')[1:])


def available(info, style):
    g = info['glyph']
    if info['kind'] == 'added':
        return 'added', 'regular'          # added 仅描边
    return ('filled' if style == 'filled' else 'regular'), style


# ---------- 代码实际使用（或退化全量） ----------
usage = defaultdict(int)
for dirpath, _, files in os.walk(LIB):
    for f in files:
        if not f.endswith('.dart'):
            continue
        txt = open(os.path.join(dirpath, f), encoding='utf-8', errors='ignore').read()
        for mm in re.findall(r'(?<![A-Za-z])Icons\.([a-zA-Z0-9_]+)', txt):
            usage[mm] += 1
if not usage:
    print('[0_gen_registry] 代码中未发现裸 Icons.*，退化为 mapping.csv 全量。')
    for r in rows:
        usage[r['material_icon']] = int(r['uses']) if r.get('uses') else 1

# ---------- 收集 (kind, glyph, eff_style) 需求并聚名 ----------
need = {}                                  # (kind,glyph,style) -> 代表 material(仅命名用)
for mat in sorted(usage):
    if mat not in mat_glyph:
        print('!! mapping.csv 缺失 material:', mat, file=sys.stderr)
        continue
    info = mat_glyph[mat]
    style = style_of(mat)
    src, eff_style = available(info, style)
    need.setdefault((info['kind'], info['glyph'], eff_style), mat)

# glyph 概念聚名；同概念多原始 glyph → 保留序数
groups = defaultdict(list)
for (kind, g, st) in need:
    groups[clean_glyph(g)].append(g)
group_has_multi = {k: len({*v}) > 1 for k, v in groups.items()}


def const_for(kind, g, st):
    concept = clean_glyph(g)
    collides = group_has_multi[concept]
    base = snake_to_camel(g if collides else concept)
    return base if st == 'filled' else base + 'Outline'


units = {}
material_map = {}
for (kind, g, st), _ in sorted(need.items()):
    const = const_for(kind, g, st)
    if const in units:
        prev = units[const]
        raise SystemExit(f'const 冲突: {const} ({kind},{g},{st}) vs {prev}')
    units[const] = {'const': const, 'kind': kind, 'glyph': g, 'style': st,
                    'src': ('added' if kind == 'added'
                            else ('filled' if st == 'filled' else 'regular')),
                    'materials': []}

# 挂 material → const
for mat in sorted(usage):
    if mat not in mat_glyph:
        continue
    info = mat_glyph[mat]
    style = style_of(mat)
    src, eff_style = available(info, style)
    hit = next((c for c, u in units.items()
                if (u['kind'], u['glyph'], u['style']) == (info['kind'], info['glyph'], eff_style)),
               None)
    if hit is None:
        raise SystemExit(f'未匹配 const: {mat}')
    units[hit]['materials'].append(mat)
    material_map[mat] = hit

# ---------- 额外字形（app 专用语义，mingcute core 全集补充） ----------
EXTRA_GLYPHS = [
    {'const': 'miniplayer', 'glyph': 'miniplayer', 'style': 'filled'},
    {'const': 'miniplayerOutline', 'glyph': 'miniplayer', 'style': 'regular'},
]
for ex in EXTRA_GLYPHS:
    if ex['const'] in units:
        raise SystemExit(f'额外字形冲突: {ex["const"]}')
    units[ex['const']] = {'const': ex['const'], 'kind': 'extra', 'glyph': ex['glyph'],
                          'style': ex['style'],
                          'src': 'filled' if ex['style'] == 'filled' else 'regular',
                          'materials': [f'(extra:{ex["glyph"]})']}

# ---------- codepoint ----------
REG_BASE, FILL_BASE = 0xE100, 0xE700
const_list = sorted(units)
for i, c in enumerate(const_list):
    base = FILL_BASE if units[c]['style'] == 'filled' else REG_BASE
    units[c]['codepoint'] = base + i
assert max(u['codepoint'] for u in units.values()) <= 0xF8FF

registry = {
    'regular_base': REG_BASE,
    'filled_base': FILL_BASE,
    'glyphs': units,
    'material': material_map,
    'usage_total': sum(usage.values()),
}
json.dump(registry, open(os.path.join(HERE, 'registry.json'), 'w', encoding='utf-8'),
          ensure_ascii=False, indent=1)

with open(os.path.join(HERE, 'eta_icons.csv'), 'w', encoding='utf-8', newline='') as f:
    w = csv.writer(f)
    w.writerow(['material', 'uses', 'eta_const', 'glyph', 'style', 'src'])
    for mat in sorted(material_map):
        c = material_map[mat]
        u = units[c]
        w.writerow([mat, usage[mat], c, u['glyph'], u['style'], u['src']])

print(f'material 名: {len(material_map)}  引用总次数: {registry["usage_total"]}')
print(f'字形数: {len(units)}  (regular {sum(1 for u in units.values() if u["style"]=="regular")} / '
      f'filled {sum(1 for u in units.values() if u["style"]=="filled")})')
