// EtaMark 独立字体族打包：把 app/eta-tools/eta_mark/svg/brand.svg 打成单字形字体
// family=EtaMark（专用品牌字形，不混入 EtaIcons），codepoint 0xE101。
// 用法：node app/eta-tools/eta_mark/2_build_font.mjs
import fs from 'node:fs';
import path from 'node:path';
import svgtofont from 'svgtofont';

const SRC = path.join(import.meta.dirname, 'svg');
const DIST = path.join(import.meta.dirname, 'dist');
const CODEPOINT = 0xE101;

fs.rmSync(DIST, { recursive: true, force: true });
fs.mkdirSync(DIST, { recursive: true });

await svgtofont({
  src: SRC,
  dist: DIST,
  fontName: 'EtaMark',
  css: false,
  outSVG: false,
  outSVGPath: false,
  svgicons2svgfont: { fontHeight: 1000, ascent: 1000, descent: 0 },
  getIconUnicode: (name, _cur, start) =>
    name === 'brand' ? [String.fromCodePoint(CODEPOINT), CODEPOINT + 1] : [_cur, start + 1],
});

console.log('EtaMark.ttf 生成 -> app/eta-tools/eta_mark/dist/EtaMark.ttf (codepoint', CODEPOINT.toString(16) + ')');
