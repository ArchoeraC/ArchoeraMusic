#!/usr/bin/env python3
# ArchoeraOS —— fcitx5 classicui 候选窗主题 “archoera” 的素材生成器。
#
# 背景：kiosk 里候选窗由 fcitx5 classicui 通过 zwp_input_popup_surface_v2 绘制。
# fcitx5 自带的 default/default-dark 是直角 + 2px 描边的老式观感，与本应用的
# 近黑、克制圆角风格不搭；KDE 生成的 plasma 主题依赖合成器模糊（我们没有模糊协议），
# 且素材来自 KDE（GPL）。故这里用 PIL **自绘**一套：
#   panel.png     候选窗底板（圆角 + 柔和投影 + 细描边）
#   highlight.png 选中候选的高亮底
#   prev/next.png 翻页箭头，arrow/radio.png 菜单图标
#
# 9 宫格：fcitx5 用 [InputPanel/Background] Margin 把图片切成 9 块（角固定、边与中心
# 拉伸）。角块必须容下「投影 + 圆角弧」，因此 Margin = SHADOW + RADIUS。
#
# 用法：python3 gen_theme.py            # 输出到 ../mkosi.extra/usr/share/fcitx5/themes/archoera
#       python3 gen_theme.py <outdir>
#
# 素材与脚本同源；theme.conf 由手写维护（见同目录 theme.conf）。
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

# 与应用 AppPalette.dark 对齐（app/lib/theme/app_theme.dart）。
PANEL_BG = (26, 26, 26, 250)      # #1A1A1A（surfacePanel #121212 提亮一档）
PANEL_BORDER = (51, 55, 63, 255)  # #33373F（outline 的冷调提亮）
HIGHLIGHT_BG = (44, 47, 54, 255)  # #2C2F36（选中候选底）
ICON = (158, 158, 158, 255)       # #9E9E9E（onSurfaceVariant）
ICON_ACCENT = (208, 211, 218, 255)  # #D0D3DA（primary）

PANEL_SIZE = 200
SHADOW = 8    # 投影宽度（图片四周留白）
RADIUS = 10   # 圆角半径（对齐 AppRadius.control）
MARGIN = SHADOW + RADIUS  # 9 宫格角块：容下投影 + 圆角弧

HIGHLIGHT_SIZE = 64
HIGHLIGHT_MARGIN = 6
HIGHLIGHT_RADIUS = 6


def _rounded_alpha(size, box, radius):
    """返回 box 内圆角矩形的抗锯齿 alpha 掩码。"""
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def _panel():
    size = (PANEL_SIZE, PANEL_SIZE)
    base = Image.new("RGBA", size, (0, 0, 0, 0))

    # 1) 投影：形状下移 2px 后高斯模糊，再压低不透明度。
    shadow_alpha = _rounded_alpha(
        size,
        (SHADOW, SHADOW + 2, PANEL_SIZE - SHADOW, PANEL_SIZE - SHADOW + 2),
        RADIUS,
    )
    shadow_alpha = shadow_alpha.filter(ImageFilter.GaussianBlur(4))
    shadow_alpha = shadow_alpha.point(lambda a: int(a * 0.42))
    shadow = Image.new("RGBA", size, (0, 0, 0, 255))
    shadow.putalpha(shadow_alpha)
    base = Image.alpha_composite(base, shadow)

    # 2) 底板：圆角矩形实底。
    bg_alpha = _rounded_alpha(
        size,
        (SHADOW, SHADOW, PANEL_SIZE - SHADOW, PANEL_SIZE - SHADOW),
        RADIUS,
    )
    bg_alpha = bg_alpha.point(lambda a: int(a * PANEL_BG[3] / 255))
    bg = Image.new("RGBA", size, PANEL_BG[:3] + (255,))
    bg.putalpha(bg_alpha)
    base = Image.alpha_composite(base, bg)

    # 3) 细描边：在内侧再画一圈 1px。
    border = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        (SHADOW, SHADOW, PANEL_SIZE - SHADOW - 1, PANEL_SIZE - SHADOW - 1),
        radius=RADIUS,
        outline=PANEL_BORDER,
        width=1,
    )
    # 描边只保留底板范围内的像素，避免溢到投影里。
    border.putalpha(ImageChops.multiply(border.split()[3], bg_alpha))
    return Image.alpha_composite(base, border)


def _highlight():
    size = (HIGHLIGHT_SIZE, HIGHLIGHT_SIZE)
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle(
        (0, 0, HIGHLIGHT_SIZE - 1, HIGHLIGHT_SIZE - 1),
        radius=HIGHLIGHT_RADIUS,
        fill=HIGHLIGHT_BG,
    )
    return img


def _chevron(size, right, color=ICON, width=2):
    s = size - 1
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if right:
        pts = [(size * 0.36, size * 0.22), (size * 0.64, size * 0.5), (size * 0.36, size * 0.78)]
    else:
        pts = [(size * 0.64, size * 0.22), (size * 0.36, size * 0.5), (size * 0.64, size * 0.78)]
    d.line([(int(x), int(y)) for x, y in pts], fill=color, width=width, joint="curve")
    _ = s
    return img


def _radio(size=16, color=ICON_ACCENT):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((3, 3, size - 3, size - 3), fill=color)
    return img


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        here, "..", "mkosi.extra", "usr", "share", "fcitx5", "themes", "archoera"
    )
    out = os.path.abspath(out)
    os.makedirs(out, exist_ok=True)

    assets = {
        "panel.png": _panel(),
        "highlight.png": _highlight(),
        "prev.png": _chevron(22, right=False),
        "next.png": _chevron(22, right=True),
        "arrow.png": _chevron(16, right=True),
        "radio.png": _radio(),
    }
    for name, img in assets.items():
        path = os.path.join(out, name)
        img.save(path)
        print(f"wrote {path} ({img.width}x{img.height})")
    print(f"9-patch margin 应为 {MARGIN}（投影 {SHADOW} + 圆角 {RADIUS}）")


if __name__ == "__main__":
    main()
