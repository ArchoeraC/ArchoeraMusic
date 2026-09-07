// eta_icons 字形准备：把「描边式」源 SVG(stroke, fill=none) 用 paperjs 扩成填充轮廓，
// 「实心式」源保持原填充 path；统一归一为单 path fill="#000"，供 svgtofont 字形化。
// 源文件从 app/eta-tools/eta_icons/source/（入库定稿子集：regular/filled/added）读取，
// 不依赖已删除的 Icon化 全量素材。
// 用法：node app/eta-tools/eta_icons/1_prepare_svg.mjs
import fs from 'node:fs';
import path from 'node:path';
import paper from 'paper';
import { PaperOffset } from 'paperjs-offset';

const HERE = import.meta.dirname;
const SRC = path.join(HERE, 'svg');
const SRC_ROOT = path.join(HERE, 'source');
const registry = JSON.parse(fs.readFileSync(path.join(HERE, 'src', 'registry.json'), 'utf8'));

paper.setup(new paper.Size(24, 24));
fs.rmSync(SRC, { recursive: true, force: true });
fs.mkdirSync(SRC, { recursive: true });

function attrs(tag) {
  const m = {};
  for (const a of tag.matchAll(/([a-zA-Z:._-]+)="([^"]*)"/g)) m[a[1]] = a[2];
  return m;
}

function num(v, fb) {
  if (v === undefined || v === '') return fb;
  const n = Number.parseFloat(v);
  return Number.isFinite(n) ? n : fb;
}

function ellipsePath(cx, cy, rx, ry) {
  return `M${cx - rx} ${cy}a${rx} ${ry} 0 1 0 ${rx * 2} 0a${rx} ${ry} 0 1 0 ${-rx * 2} 0Z`;
}

/** 描边扩轮廓：可绘制子路径用 paperjs-offset 扩边；极短(round-cap 圆点)子路径转实心圆。 */
function rectPath(a) {
  const x = num(a.x, 0), y = num(a.y, 0), w = num(a.width, 0), h = num(a.height, 0);
  let rx = num(a.rx, 0), ry = num(a.ry, rx);
  rx = Math.min(Math.max(rx, 0), w / 2); ry = Math.min(Math.max(ry, 0), h / 2);
  if (!rx && !ry) return `M${x} ${y}H${x + w}V${y + h}H${x}Z`;
  return `M${x + rx} ${y}H${x + w - rx}A${rx} ${ry} 0 0 1 ${x + w} ${y + ry}V${y + h - ry}A${rx} ${ry} 0 0 1 ${x + w - rx} ${y + h}H${x + rx}A${rx} ${ry} 0 0 1 ${x} ${y + h - ry}V${y + ry}A${rx} ${ry} 0 0 1 ${x + rx} ${y}Z`;
}

/** 描边扩轮廓：可绘制子路径用 paperjs-offset 扩边；极短(round-cap 圆点)子路径转实心圆。 */
function expandStrokeToPath({ path: d, sw, cap, join }) {
  const item = paper.PathItem.create(d);
  try {
    const subs = item instanceof paper.CompoundPath ? [...item.children] : [item];
    const out = [];
    const minLen = Math.max(1e-6, sw * 0.01);
    for (const p of subs) {
      const drawable = p.length > minLen && p.segments.length > 1;
      if (!drawable) {
        // 极短线（长度≈0 的 tick/dot）：CSS 用 round linecap 渲染成圆点 →
        // 直接落一个半径 sw/2 的实心圆，避免字形丢点/变空
        const pt = p.firstSegment?.point;
        if (pt) out.push(ellipsePath(pt.x, pt.y, sw / 2, sw / 2));
        continue;
      }
      const o = PaperOffset.offsetStroke(p, sw / 2, { cap, join, insert: false });
      if (o?.pathData) out.push(o.pathData);
      o?.remove();
    }
    return out.join('');
  } finally {
    item.remove();
  }
}

/** 把一个 SVG 文本解析出各图形元素；返回填充几何列表[{d, evenodd?}] 及描边几何列表[{d, sw, cap, join}] */
function parseGeometry(svgText) {
  const fills = [], strokes = [];
  const body = svgText.replace(/<\?xml[\s\S]*?\?>/, '').replace(/<!--[\s\S]*?-->/g, '');
  // Tabler 等外部源把 stroke 默认值写在根 <svg>（子元素继承），这里取根默认
  const rootM = body.match(/^<svg([\s\S]*?)>/);
  const rootAttrs = rootM ? attrs(rootM[1]) : {};
  const def = {
    stroke: rootAttrs.stroke,
    fill: rootAttrs.fill,
    sw: num(rootAttrs['stroke-width'], 2),
    cap: rootAttrs['stroke-linecap'] === 'round' ? 'round' : 'butt',
    join: rootAttrs['stroke-linejoin'] === 'round' ? 'round' : 'miter',
  };
  for (const m of body.matchAll(/<(path|circle|ellipse|rect|line|polyline|polygon)([\s\S]*?)\/?>/g)) {
    const tag = m[1], a = attrs(m[2]);
    const stroke = a.stroke ?? def.stroke;
    const fill = a.fill ?? def.fill;
    if (tag === 'path' && a.d) {
      if (stroke && stroke !== 'none') {
        strokes.push({ path: a.d, sw: num(a['stroke-width'], def.sw), cap: a['stroke-linecap'] === 'round' ? 'round' : a['stroke-linecap'] === 'butt' ? 'butt' : def.cap, join: a['stroke-linejoin'] === 'round' ? 'round' : a['stroke-linejoin'] === 'miter' ? 'miter' : def.join });
      }
      if (fill && fill !== 'none') fills.push({ d: a.d, evenodd: a['fill-rule'] === 'evenodd' });
      continue;
    }
    let d;
    if (tag === 'circle') d = ellipsePath(num(a.cx), num(a.cy), num(a.r), num(a.r));
    else if (tag === 'ellipse') d = ellipsePath(num(a.cx), num(a.cy), num(a.rx), num(a.ry));
    else if (tag === 'rect') d = rectPath(a);
    else if (tag === 'line') d = `M${num(a.x1)} ${num(a.y1)}L${num(a.x2)} ${num(a.y2)}`;
    else if (tag === 'polyline' || tag === 'polygon') {
      const pts = (a.points || '').trim();
      d = `M${pts}${tag === 'polygon' ? 'Z' : ''}`;
    }
    if (!d) continue;
    if (stroke && stroke !== 'none') strokes.push({ path: d, sw: num(a['stroke-width'], def.sw), cap: a['stroke-linecap'] === 'round' ? 'round' : a['stroke-linecap'] === 'butt' ? 'butt' : def.cap, join: a['stroke-linejoin'] === 'round' ? 'round' : a['stroke-linejoin'] === 'miter' ? 'miter' : def.join });
    if (fill && fill !== 'none') fills.push({ d, evenodd: false });
  }
  return { fills, strokes };
}

function buildSvg(geoms) {
  // 组合：fill 几何 + 扩边后的描边几何，黑色填充；nonzero 已由 paperjs 保证孔洞方向
  const all = [];
  for (const f of geoms.fills) all.push(f.evenodd ? `<path fill-rule="evenodd" d="${f.d}"/>` : `<path d="${f.d}"/>`);
  for (const s of geoms.strokes) {
    const d = expandStrokeToPath(s);
    if (d) all.push(`<path d="${d}"/>`);
  }
  return `<svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">${all.join('')}</svg>`;
}

let prepared = 0, skipped = 0, failed = [];

for (const [constName, u] of Object.entries(registry.glyphs)) {
  // 源统一取自 source/：added → source/added；其余(regular 描边/filled 实心)按 style
  const sub = u.kind === 'added' ? 'added' : (u.style === 'filled' ? 'filled' : 'regular');
  const p = path.join(SRC_ROOT, sub, `${u.glyph}.svg`);
  let raw;
  try {
    raw = fs.readFileSync(p, 'utf8');
  } catch {
    failed.push(`${constName} (source/${sub}/${u.glyph}.svg 缺失)`);
    continue;
  }
  const geoms = parseGeometry(raw);
  if (!geoms.fills.length && !geoms.strokes.length) { failed.push(constName); continue; }
  const svg = buildSvg(geoms);
  fs.writeFileSync(path.join(SRC, `${constName}.svg`), svg);
  prepared++;
}
console.log(`prepared ${prepared} glyphs -> app/eta-tools/eta_icons/svg`);
if (failed.length) console.log('EMPTY:', failed.slice(0, 20), `(${failed.length} total)`);
