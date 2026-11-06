#!/usr/bin/env python3
"""生成 app 图标：Resources/AppIcon.icns

设计：macOS 圆角方形渐变底（蓝 → 紫），中间是浏览器窗口轮廓，右下角一枚
白色指针（带深紫描边，和窗口线条分得开），表达"为链接挑一个浏览器"。

用法：
    python3 scripts/make-icon.py            # 生成 Resources/AppIcon.icns 与 docs/icon.png
    python3 scripts/make-icon.py --preview  # 只输出 /tmp 预览图，不动仓库文件
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
DOCS = ROOT / "docs"

# 设计稿坐标系固定为 1024，渲染时按目标尺寸缩放。
BASE = 1024.0
CONTENT = 824.0          # macOS 圆角方形在 1024 画布上占 824
CORNER_RADIUS = 185.0

GRADIENT_FROM = (78, 140, 255)
GRADIENT_TO = (108, 58, 232)

WINDOW_BOX = (262.0, 220.0, 682.0, 640.0)
WINDOW_RADIUS = 96.0
WINDOW_STROKE = 44.0
TITLE_BAR_Y = 332.0
TITLE_BAR_INSET = 56.0
TITLE_BAR_STROKE = 32.0

CURSOR_TIP = (580.0, 512.0)
CURSOR_SCALE = 280.0
# 标准指针轮廓，原点在笔尖，y 轴向下。
CURSOR_PATH = [
    (0.00, 0.00),
    (0.00, 0.72),
    (0.20, 0.55),
    (0.34, 0.88),
    (0.47, 0.81),
    (0.33, 0.49),
    (0.57, 0.47),
]
CURSOR_RIM = 28.0
CURSOR_RIM_COLOR = (48, 24, 128, 255)


def gradient_background(size: int) -> Image.Image:
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    t = ((x + y) / (2.0 * (size - 1))) ** 0.92
    start = np.array(GRADIENT_FROM, dtype=np.float32)
    end = np.array(GRADIENT_TO, dtype=np.float32)
    rgb = start[None, None, :] * (1.0 - t)[..., None] + end[None, None, :] * t[..., None]

    # 左上柔光
    nx = x / (size - 1)
    ny = y / (size - 1)
    glow = np.clip(1.0 - np.hypot(nx - 0.24, ny - 0.10) / 0.78, 0.0, 1.0) ** 2.2
    rgb += (255.0 - rgb) * (glow * 0.26)[..., None]

    # 右下轻微压暗，增加体积感
    vignette = np.clip(np.hypot(nx - 1.0, ny - 1.0) / 0.85, 0.0, 1.0) ** 2.0
    rgb -= (rgb - 12.0) * (vignette * 0.16)[..., None]

    rgba = np.dstack([np.clip(rgb, 0, 255), np.full((size, size), 255.0, np.float32)])
    return Image.fromarray(rgba.astype(np.uint8), "RGBA")


def rounded_mask(size: int, box: tuple[float, float, float, float], radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def line_with_caps(draw: ImageDraw.ImageDraw, p0, p1, width: float, fill):
    draw.line([p0, p1], fill=fill, width=int(round(width)))
    r = width / 2.0
    for x, y in (p0, p1):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def small_size_boost(size: int) -> float:
    # 小尺寸加粗笔画，避免 16/32px 下线条糊成一片
    if size <= 16:
        return 1.75
    if size <= 32:
        return 1.4
    if size <= 64:
        return 1.18
    return 1.0


def render(size: int, supersample: int) -> Image.Image:
    px = size * supersample
    s = px / BASE
    S = lambda v: v * s
    boost = small_size_boost(size)

    icon = Image.new("RGBA", (px, px), (0, 0, 0, 0))

    # 圆角方形底 + 投影
    inset = S((BASE - CONTENT) / 2.0)
    content_box = (inset, inset, S((BASE + CONTENT) / 2.0), S((BASE + CONTENT) / 2.0))
    shape = rounded_mask(px, content_box, S(CORNER_RADIUS))

    shadow = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (0, 0), rounded_mask(
        px,
        (content_box[0], content_box[1] + S(16), content_box[2], content_box[3] + S(16)),
        S(CORNER_RADIUS),
    ))
    shadow = shadow.filter(ImageFilter.GaussianBlur(S(14)))
    icon.alpha_composite(shadow)
    icon.paste(gradient_background(px), (0, 0), shape)

    # 顶部内侧高光
    inner = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    ImageDraw.Draw(inner).rounded_rectangle(
        (content_box[0] + S(3), content_box[1] + S(3), content_box[2] - S(3), content_box[3] - S(3)),
        radius=S(CORNER_RADIUS - 3),
        outline=(255, 255, 255, 44),
        width=max(1, int(round(S(3)))),
    )
    inner.putalpha(ImageChops.multiply(inner.getchannel("A"), shape))
    icon.alpha_composite(inner)

    # 窗口轮廓
    glyph = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glyph)
    wb = tuple(S(v) for v in WINDOW_BOX)
    gd.rounded_rectangle(wb, radius=S(WINDOW_RADIUS), outline=(255, 255, 255, 244),
                         width=int(round(S(WINDOW_STROKE * boost))))
    line_with_caps(
        gd,
        (wb[0] + S(TITLE_BAR_INSET), S(TITLE_BAR_Y)),
        (wb[2] - S(TITLE_BAR_INSET), S(TITLE_BAR_Y)),
        S(TITLE_BAR_STROKE * boost),
        (255, 255, 255, 170),
    )

    # 指针：深紫描边 + 白填充 + 柔和投影
    pts = [(S(CURSOR_TIP[0] + x * CURSOR_SCALE), S(CURSOR_TIP[1] + y * CURSOR_SCALE)) for x, y in CURSOR_PATH]
    rim_width = max(1, int(round(S(CURSOR_RIM) * min(boost, 1.6))))

    cursor_shadow = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    sd = ImageDraw.Draw(cursor_shadow)
    sd.polygon(pts, fill=(0, 0, 0, 110))
    sd.line(pts + [pts[0]], fill=(0, 0, 0, 110), width=rim_width, joint="curve")
    cursor_shadow = cursor_shadow.filter(ImageFilter.GaussianBlur(S(10)))
    cursor_shadow = ImageChops.offset(cursor_shadow, int(S(7)), int(S(12)))
    glyph.alpha_composite(cursor_shadow)

    cd = ImageDraw.Draw(glyph)
    cd.line(pts + [pts[0]], fill=CURSOR_RIM_COLOR, width=rim_width, joint="curve")
    for x, y in pts:
        r = rim_width / 2.0
        cd.ellipse([x - r, y - r, x + r, y + r], fill=CURSOR_RIM_COLOR)
    cd.polygon(pts, fill=(255, 255, 255, 255))

    glyph.putalpha(ImageChops.multiply(glyph.getchannel("A"), shape))
    icon.alpha_composite(glyph)

    return icon.resize((size, size), Image.LANCZOS)


def build_sizes() -> dict[int, Image.Image]:
    images = {}
    for size in (16, 32, 64, 128, 256, 512, 1024):
        supersample = 4 if size <= 256 else 2
        images[size] = render(size, supersample)
    return images


def write_icns(images: dict[int, Image.Image]) -> Path:
    iconset = ROOT / "build" / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True)
    for base_size in (16, 32, 128, 256, 512):
        images[base_size].save(iconset / f"icon_{base_size}x{base_size}.png")
        images[base_size * 2].save(iconset / f"icon_{base_size}x{base_size}@2x.png")

    target = RESOURCES / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(target)], check=True)
    return target


def write_sheet(images: dict[int, Image.Image]) -> Path:
    sheet = Image.new("RGBA", (760, 260), (246, 246, 248, 255))
    x = 24
    for size in (16, 32, 64, 128, 256):
        sheet.alpha_composite(images[size], (x, 130 - size // 2))
        x += size + 34
    path = Path("/tmp/browser-selector-icon-sheet.png")
    sheet.convert("RGB").save(path)
    return path


def main() -> int:
    images = build_sizes()
    if "--preview" in sys.argv:
        print(write_sheet(images))
        images[1024].save("/tmp/browser-selector-icon-1024.png")
        print("/tmp/browser-selector-icon-1024.png")
        return 0

    icns = write_icns(images)
    DOCS.mkdir(exist_ok=True)
    preview = DOCS / "icon.png"
    images[1024].save(preview)
    print(f"{icns} ({icns.stat().st_size // 1024} KB)")
    print(preview)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
