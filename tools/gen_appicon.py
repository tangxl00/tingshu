#!/usr/bin/env python3
"""生成听书 App 图标全尺寸 PNG，输出到 AppIcon.appiconset。

设计：深蓝→青渐变背景 + 白色「听」字 + 声波弧线（纯本地绘制，无外部素材）。
iOS 会自动裁圆角，画布保持全幅正方形、无透明通道。
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parents[1] / "ios/TingYou/TingYou/Resources/Assets.xcassets/AppIcon.appiconset"
OUT.mkdir(parents=True, exist_ok=True)

FONT_PATH = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"

# 需要的尺寸(px)：filename -> size
SIZES = {
    "icon-40.png": 40,    # iPhone/iPad 20pt@2x
    "icon-58.png": 58,    # 29pt@2x
    "icon-60.png": 60,    # 20pt@3x
    "icon-76.png": 76,    # iPad 76pt@1x（保守保留）
    "icon-80.png": 80,    # 40pt@2x（备用）
    "icon-87.png": 87,    # 29pt@3x
    "icon-120.png": 120,  # 60pt@2x
    "icon-152.png": 152,  # iPad 76pt@2x
    "icon-167.png": 167,  # iPad Pro 83.5pt@2x
    "icon-180.png": 180,  # 60pt@3x
    "icon-1024.png": 1024,  # App Store marketing
}


def build_icon(size: int) -> Image.Image:
    S = 1024  # 在高分辨率画布上绘制，再高质量缩放
    img = Image.new("RGB", (S, S), "#1B2C4F")
    d = ImageDraw.Draw(img)

    # 垂直渐变：深蓝 #1B2C4F -> 青蓝 #2E7DAF
    top = (0x1B, 0x2C, 0x4F)
    bottom = (0x2E, 0x7D, 0xAF)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))

    cx, cy = S / 2, S / 2

    # 声波弧线（右上角装饰，白色半透明效果用亮色模拟）
    for i, (r, w) in enumerate([(330, 26), (415, 26), (500, 26)]):
        alpha = 1.0 - i * 0.28
        col = tuple(int(c * alpha + 255 * (1 - alpha) * 0.15) for c in (255, 255, 255))
        bbox = [cx + r * 0.25 - r, cy - r - r * 0.9 + r * 0.55, cx + r * 0.25 + r, cy - r + r * 2.45]
        d.arc(bbox, start=-60, end=60, fill=col, width=w)

    # 「听」字居中，白色
    font = ImageFont.truetype(FONT_PATH, 520)
    text = "听"
    bbox = d.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    d.text((cx - tw / 2 - bbox[0], cy - th / 2 - bbox[1]), text, font=font, fill="#FFFFFF")

    # 底部小字「TINGSHU」增加品牌识别
    small = ImageFont.truetype(FONT_PATH, 86)
    label = "TINGSHU"
    bbox2 = d.textbbox((0, 0), label, font=small)
    lw = bbox2[2] - bbox2[0]
    d.text(((S - lw) / 2 - bbox2[0], S * 0.80), label, font=small, fill=(255, 255, 255))

    if size == S:
        return img
    return img.resize((size, size), Image.LANCZOS)


for name, size in SIZES.items():
    build_icon(size).save(OUT / name, "PNG")
    print(f"{name}: {size}x{size}")

print("done ->", OUT)
