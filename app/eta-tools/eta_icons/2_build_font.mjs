// eta_icons 字体打包：把 app/eta-tools/eta_icons/svg 下已归一化 glyph 打成单一字体族 EtaIcons
// （regular/描边 与 filled/实心 同文件双 codepoint 区段），产物：
//   app/eta-tools/eta_icons/dist/EtaIcons.ttf / .woff2（再拷贝到 app/assets/fonts/）
// 用法：node app/eta-tools/eta_icons/2_build_font.mjs
import fs from 'node:fs';
import path from 'node:path';
import svgtofont from 'svgtofont';

const HERE = import.meta.dirname;
const SRC = path.join(HERE, 'svg');
const DIST = path.join(HERE, 'dist');
const registry = JSON.parse(fs.readFileSync(path.join(HERE, 'src', 'registry.json'), 'utf8'));

fs.rmSync(DIST, { recursive: true, force: true });
fs.mkdirSync(DIST, { recursive: true });

await svgtofont({
  src: SRC,
  dist: DIST,
  fontName: 'EtaIcons',
  css: false,
  outSVG: false,
  outSVGPath: false,
  svgicons2svgfont: { fontHeight: 1000, ascent: 1000, descent: 0 },
  getIconUnicode: (name, _cur, start) => {
    const cp = registry.glyphs[name]?.codepoint;
    if (cp == null) return [_cur, start + 1];
    return [String.fromCodePoint(cp), cp + 1];
  },
});

// 校验产物 metrics 与字形数
const ttf = path.join(DIST, 'EtaIcons.ttf');
if (!fs.existsSync(ttf)) throw new Error('ttf 未生成');
console.log('EtaIcons.ttf 已生成 -> app/eta-tools/eta_icons/dist/EtaIcons.ttf');
