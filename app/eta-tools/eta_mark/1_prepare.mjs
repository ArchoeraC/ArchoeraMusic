// EtaMark 品牌字形准备：把 logo-trim.png（白形透明底）二值化 → potrace 矢量化
// → 归一化到 24 单位 SVG，供 svgtofont 打成独立字体族 EtaMark。
// 用法：node app/eta-tools/eta_mark/1_prepare.mjs
import fs from 'node:fs';
import path from 'node:path';
import { Potrace } from 'potrace';
import { execFileSync } from 'node:child_process';

const PNG = process.argv[2] ?? path.join(import.meta.dirname, 'source', 'logo-trim.png');
const OUT = path.join(import.meta.dirname, 'svg');

fs.mkdirSync(OUT, { recursive: true });

// 1. PNG → 二值 BMP：前景(alpha>60)=黑0，背景=白255
const bmp = path.join(import.meta.dirname, '.logo_bin.bmp');
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

// 3. 提取 path d
const dm = svgRaw.match(/<path d="([^"]*)"/);
if (!dm) throw new Error('potrace 无 path');
const dRaw = dm[1];

// 4. 归一化：以 path 坐标范围 fit 到 viewBox 0 0 24 24（留 1 单位 padding）
const nums = (dRaw.match(/-?\d+\.?\d*/g) ?? []).map(Number);
const xs = nums.filter((_, i) => i % 2 === 0);
const ys = nums.filter((_, i) => i % 2 === 1);
const minX = Math.min(...xs), maxX = Math.max(...xs);
const minY = Math.min(...ys), maxY = Math.max(...ys);
const scale = 22 / Math.max(maxX - minX, maxY - minY);
const offX = (24 - (maxX - minX) * scale) / 2 - minX * scale;
const offY = (24 - (maxY - minY) * scale) / 2 - minY * scale;

// 简单坐标重映射：potrace path 里数字形式为 "x y, x y" —— 用 svgpath 转换更稳，但手写数值级替换有风险。
// 这里采用基于 svgpath npm 的 transform 方式。
const svgpath = (await import('svgpath')).default;
const dMapped = svgpath(dRaw).scale(scale).translate(offX, offY).round(3).toString();

const svg = `<svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="${dMapped}"/></svg>`;
fs.writeFileSync(path.join(OUT, 'brand.svg'), svg, 'utf8');
fs.rmSync(bmp, { force: true });
console.log('EtaMark brand.svg written; bbox', { minX, maxX, minY, maxY }, 'scale', scale.toFixed(4));
