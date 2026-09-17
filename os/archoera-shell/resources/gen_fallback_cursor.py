#!/usr/bin/env python3
"""生成合成器内置兜底光标 `cursor.rgba`（32×32，预乘 RGBA，热点 (1,1)）。

XCursor 主题缺失（无 `/usr/share/icons/*/cursors`）时使用；正常情况优先
加载系统主题，并可在 GUI 里由客户端 `wl_pointer.set_cursor` 覆盖。

用法：`python3 resources/gen_fallback_cursor.py`（需 Pillow），
输出 `resources/cursor.rgba`。
"""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 32
ARROW = [(0, 0), (0, 19), (5, 14), (9, 23), (13, 21), (8, 13), (15, 13)]

OUT = Path(__file__).with_name("cursor.rgba")


def main() -> None:
    # 4 倍超采样后缩小，得到平滑边缘。
    scale = 4
    img = Image.new("RGBA", (SIZE * scale, SIZE * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    pts = [(x * scale, y * scale) for x, y in ARROW]
    draw.polygon(pts, fill=(255, 255, 255, 255))
    draw.line(pts + [pts[0]], fill=(0, 0, 0, 255), width=scale, joint="curve")
    img = img.resize((SIZE, SIZE), Image.LANCZOS)

    # 预乘 alpha（渲染器按预乘 ARGB8888 解释）。
    raw = img.tobytes()
    pixels = []
    for i in range(0, len(raw), 4):
        r, g, b, a = raw[i], raw[i + 1], raw[i + 2], raw[i + 3]
        pixels += [r * a // 255, g * a // 255, b * a // 255, a]

    OUT.write_bytes(bytes(pixels))
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
