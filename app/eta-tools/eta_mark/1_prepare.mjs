// EtaMark 品牌字形准备：把源图（白形透明底）二值化 → potrace 矢量化
// → 归一化到 24 单位 SVG，供 svgtofont 打成独立字体族 EtaMark。
// 源图：source/logo-trim.png（brand，均衡器频谱）/ source/erasync.png（erasync，圆角方+波形）
// 用法：node app/eta-tools/eta_mark/1_prepare.mjs
import fs from 'node:fs';
import path from 'node:path';
import { Potrace } from 'potrace';
import { execFileSync } from 'node:child_process';
import svgpath from 'svgpath';

const SRC = path.join(import.meta.dirname, 'source');
const OUT = path.join(import.meta.dirname, 'svg');

fs.mkdirSync(OUT, { recursive: true });

// 源图 → 字形名（新增品牌字形在这里登记）。
const JOBS = [
  { name: 'brand', png: 'logo-trim.png' },
  { name: 'erasync', png: 'erasync.png' },
];

// ── 子路径绕向归一 ────────────────────────────────────────────────
// potrace 依赖 evenodd 填充（洞与外轮廓可同向），而字体（svgicons2svgfont）
// 按 nonzero 绕向判定洞；故把与外轮廓同向的子路径反向，保证洞在字体里也是洞。
const splitSubpaths = (d) => d.match(/M[^M]*/g) ?? [d];

function signedArea(sub) {
  const toks = sub.match(/[MCZ]|-?\d+\.?\d*/g) ?? [];
  const pts = [];
  let i = 0;
  while (i < toks.length) {
    const t = toks[i];
    if (t === 'M') { pts.push([+toks[i + 1], +toks[i + 2]]); i += 3; }
    else if (t === 'C') {
      i += 1;
      while (i + 5 < toks.length && /^-?\d/.test(toks[i])) {
        pts.push([+toks[i + 4], +toks[i + 5]]);
        i += 6;
      }
    } else i += 1;
  }
  let a = 0;
  for (let k = 0; k < pts.length; k++) {
    const [x1, y1] = pts[k], [x2, y2] = pts[(k + 1) % pts.length];
    a += x1 * y2 - x2 * y1;
  }
  return a / 2;
}

function reverseSubpath(sub) {
  const toks = sub.match(/[MCZ]|-?\d+\.?\d*/g) ?? [];
  const segs = [];
  let cur = null, i = 0;
  while (i < toks.length) {
    const t = toks[i];
    if (t === 'M') { cur = [+toks[i + 1], +toks[i + 2]]; i += 3; }
    else if (t === 'C') {
      i += 1;
      while (i + 5 < toks.length && /^-?\d/.test(toks[i])) {
        const c1 = [+toks[i], +toks[i + 1]], c2 = [+toks[i + 2], +toks[i + 3]], e = [+toks[i + 4], +toks[i + 5]];
        segs.push([cur, c1, c2, e]); cur = e; i += 6;
      }
    } else i += 1;
  }
  if (!segs.length) return sub;
  const rev = segs.reverse().map(([s, c1, c2, e]) => [e, c2, c1, s]);
  const f = (n) => n.toFixed(3);
  let d = `M ${f(rev[0][0][0])} ${f(rev[0][0][1])}`;
  for (const [, c1, c2, e] of rev) {
    d += ` C ${f(c1[0])} ${f(c1[1])} ${f(c2[0])} ${f(c2[1])} ${f(e[0])} ${f(e[1])}`;
  }
  return d;
}

function normalizeWinding(d) {
  const subs = splitSubpaths(d);
  if (subs.length < 2) return d;
  const outer = signedArea(subs[0]);
  return subs
    .map((s, k) => (k === 0 || Math.sign(signedArea(s)) !== Math.sign(outer) ? s : reverseSubpath(s)))
    .join(' ');
}

for (const { name, png } of JOBS) {
  const PNG = path.join(SRC, png);

  // 1. PNG → 二值 BMP：前景(alpha>60)=黑0，背景=白255
  const bmp = path.join(import.meta.dirname, `.${name}_bin.bmp`);
  execFileSync('python3', ['-c', `
from PIL import Image
im=Image.open('${PNG}').convert('RGBA')
w,h=im.size; px=im.load()
out=Image.new('L',(w,h),255); op=out.load()
for y in range(h):
    for x in range(w):
        if px[x,y][3]>60: op[x,y]=0
out.save('${bmp}')
`], { stdio: 'inherit' });

  // 2. potrace → svg（自动转贝塞尔）
  const svgRaw = await new Promise((resolve, reject) => {
    const p = new Potrace({ threshold: 128, turdSize: 2 });
    p.loadImage(bmp, (err) => (err ? reject(err) : resolve(p.getSVG())));
  });

  // 3. 提取 path d（potrace 可能产出多条子路径，全部保留）
  const dRaw = [...svgRaw.matchAll(/<path[^>]*\sd="([^"]*)"/g)]
    .map((m) => m[1])
    .join(' ');
  if (!dRaw) throw new Error(`${name}: potrace 无 path`);

  // 4. 归一化：以 path 坐标范围 fit 到 viewBox 0 0 24 24（留 1 单位 padding）
  const nums = (dRaw.match(/-?\d+\.?\d*/g) ?? []).map(Number);
  const xs = nums.filter((_, i) => i % 2 === 0);
  const ys = nums.filter((_, i) => i % 2 === 1);
  const minX = Math.min(...xs), maxX = Math.max(...xs);
  const minY = Math.min(...ys), maxY = Math.max(...ys);
  const scale = 22 / Math.max(maxX - minX, maxY - minY);
  const offX = (24 - (maxX - minX) * scale) / 2 - minX * scale;
  const offY = (24 - (maxY - minY) * scale) / 2 - minY * scale;

  // potrace path 数字形式为 "x y, x y" —— 用 svgpath transform 重映射（含洞）
  const dMapped = normalizeWinding(
    svgpath(dRaw).scale(scale).translate(offX, offY).round(3).toString(),
  );

  const svg = `<svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" d="${dMapped}"/></svg>`;
  fs.writeFileSync(path.join(OUT, `${name}.svg`), svg, 'utf8');
  fs.rmSync(bmp, { force: true });
  console.log(`EtaMark ${name}.svg written; bbox`, { minX, maxX, minY, maxY }, 'scale', scale.toFixed(4));
}
