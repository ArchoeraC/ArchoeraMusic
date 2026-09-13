// EtaMark 独立字体族打包：把 app/eta-tools/eta_mark/svg/*.svg 打成品牌字形字体
// family=EtaMark（专用品牌字形，不混入 EtaIcons）。
// codepoint：brand=0xE101（均衡器频谱）/ erasync=0xE102（圆角方+波形）。
// 用法：node app/eta-tools/eta_mark/2_build_font.mjs
import fs from 'node:fs';
import path from 'node:path';
import svgtofont from 'svgtofont';

const SRC = path.join(import.meta.dirname, 'svg');
const DIST = path.join(import.meta.dirname, 'dist');

// 字形 → 码位（新增品牌字形在这里登记，与 eta_mark.dart 常量保持一致）。
const CODEPOINTS = { brand: 0xE101, erasync: 0xE102 };

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
  getIconUnicode: (name, _cur, start) => {
    const cp = CODEPOINTS[name];
    return cp ? [String.fromCodePoint(cp), cp + 1] : [_cur, start + 1];
  },
});

console.log('EtaMark.ttf 生成 -> app/eta-tools/eta_mark/dist/EtaMark.ttf (glyphs:', Object.keys(CODEPOINTS).join(', ') + ')');
