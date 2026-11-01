"""生成 Android 启动图标（ic_launcher）与自适应图标前景。

图标主题：一个简洁的数据库圆柱，用于「数据库」这个伪装名。
运行：python tool/generate_icon.py
"""

from __future__ import annotations

import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android" / "app" / "src" / "main" / "res"

# 旧版图标尺寸（mdpi ~ xxxhdpi）
LEGACY_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# 自适应图标前景：108dp 画布
FOREGROUND_SIZES = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

BASE = 1024
BG_TOP = (30, 38, 54)
BG_BOTTOM = (13, 16, 22)
CYL_TOP = (122, 175, 255)
CYL_BOTTOM = (43, 104, 219)
CYL_LIGHT = (170, 208, 255)


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(img)
    for y in range(size):
        t = y / max(size - 1, 1)
        color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        draw.line([(0, y), (size, y)], fill=(*color, 255))
    return img


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def draw_cylinder(canvas: Image.Image, cx: float, cy: float, width: float, height: float) -> None:
    """在 canvas 上画一个数据库圆柱。"""
    draw = ImageDraw.Draw(canvas, "RGBA")
    ry = height * 0.135
    left = cx - width / 2
    right = cx + width / 2
    top = cy - height / 2
    bottom = cy + height / 2

    # 柱体（渐变）
    body_top = int(top + ry)
    body_bottom = int(bottom - ry)
    for y in range(body_top, body_bottom + 1):
        t = (y - body_top) / max(body_bottom - body_top, 1)
        color = tuple(int(CYL_TOP[i] + (CYL_BOTTOM[i] - CYL_TOP[i]) * t) for i in range(3))
        draw.line([(left, y), (right, y)], fill=(*color, 255))

    # 底部圆弧
    draw.ellipse([left, bottom - 2 * ry, right, bottom], fill=(*CYL_BOTTOM, 255))

    # 分层刻线（用不透明浅色，避免在透明前景上叠加成黑边）
    for fraction in (0.42, 0.66):
        y = top + height * fraction
        draw.arc(
            [left, y - ry, right, y + ry],
            start=185,
            end=355,
            fill=(206, 226, 255, 255),
            width=max(3, int(width * 0.014)),
        )

    # 顶面：外圈浅色 + 内圈稍深，形成"盖子"的层次
    draw.ellipse([left, top, right, top + 2 * ry], fill=(*CYL_LIGHT, 255))
    draw.ellipse(
        [left + width * 0.10, top + ry * 0.45, right - width * 0.10, top + 2 * ry - ry * 0.35],
        fill=(96, 152, 240, 255),
    )


def build_legacy(size: int) -> Image.Image:
    bg = vertical_gradient(BASE, BG_TOP, BG_BOTTOM)
    mask = rounded_mask(BASE, int(BASE * 0.235))
    icon = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), mask)

    draw_cylinder(icon, BASE * 0.5, BASE * 0.5, BASE * 0.46, BASE * 0.54)
    return icon.resize((size, size), Image.LANCZOS)


def build_foreground(size: int) -> Image.Image:
    canvas = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    # 自适应图标安全区约为画布的 66%，圆柱控制在 56% 左右。
    draw_cylinder(canvas, BASE * 0.5, BASE * 0.5, BASE * 0.40, BASE * 0.46)
    return canvas.resize((size, size), Image.LANCZOS)


def main() -> None:
    for folder, size in LEGACY_SIZES.items():
        out = RES / folder / "ic_launcher.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        build_legacy(size).save(out, "PNG")
        print(f"legacy   {out.relative_to(ROOT)} {size}x{size}")

    for folder, size in FOREGROUND_SIZES.items():
        out = RES / folder / "ic_launcher_foreground.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        build_foreground(size).save(out, "PNG")
        print(f"foreground {out.relative_to(ROOT)} {size}x{size}")

    preview = ROOT / "tool" / "icon_preview.png"
    build_legacy(512).save(preview, "PNG")
    print(f"preview  {preview.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
