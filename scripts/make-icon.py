#!/usr/bin/env python3
"""生成 AppIcon.icns：深蓝圆角方块 + 白色对话气泡。"""
from PIL import Image, ImageDraw
import os, subprocess, shutil

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# 圆角底：垂直渐变 #1C6BFF -> #0A3C9E
top, bottom = (28, 107, 255), (10, 60, 158)
radius = 230
grad = Image.new("RGB", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    t = y / (S - 1)
    gd.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([48, 48, S - 48, S - 48], radius=radius, fill=255)
img.paste(grad, (0, 0), mask)

# 对话气泡
bubble = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bd = ImageDraw.Draw(bubble)
bd.rounded_rectangle([250, 292, 774, 660], radius=110, fill=(255, 255, 255, 255))
bd.polygon([(330, 650), (330, 790), (470, 656)], fill=(255, 255, 255, 255))
for cx in (390, 512, 634):
    bd.ellipse([cx - 34, 440, cx + 34, 508], fill=(18, 74, 190, 255))
img = Image.alpha_composite(img, bubble)
img.save("Resources/AppIcon-1024.png")

iconset = "Resources/AppIcon.iconset"
shutil.rmtree(iconset, ignore_errors=True)
os.makedirs(iconset)
specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for base, scale in specs:
    size = base * scale
    name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
    img.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", "Resources/AppIcon.icns"], check=True)
print("icon written:", os.path.getsize("Resources/AppIcon.icns"), "bytes")
