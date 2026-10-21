#!/usr/bin/env python3
"""Draws the Screen Translator app icon and writes the asset catalog.
Usage: python scripts/make_icon.py App/Assets.xcassets
No fonts needed - everything is drawn from shapes."""
import json
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT = sys.argv[1] if len(sys.argv) > 1 else "App/Assets.xcassets"
S = 2048  # drawn at 2x, saved at 1024 for smooth edges


def rr(draw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def shadow(base, box, radius, blur, offset=(0, 40), alpha=110):
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    ImageDraw.Draw(layer).rounded_rectangle(
        (x0 + offset[0], y0 + offset[1], x1 + offset[0], y1 + offset[1]),
        radius=radius, fill=(10, 10, 40, alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    base.alpha_composite(layer)


# --- background: diagonal blue -> indigo gradient -------------------------
top = Image.new("RGB", (S, S), (64, 140, 255))
bottom = Image.new("RGB", (S, S), (118, 80, 250))
big = Image.linear_gradient("L").resize((S * 2, S * 2))      # larger than the icon so rotated corners stay filled
big = big.rotate(35, resample=Image.BICUBIC)
mask = big.crop((S // 2, S // 2, S // 2 + S, S // 2 + S))
img = Image.composite(bottom, top, mask).convert("RGBA")

# soft light blob top-left for depth
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse((-500, -600, 1100, 900), fill=(255, 255, 255, 60))
img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(160)))

# --- back card: the screen with the original text ---------------------------
back = (230, 330, 1560, 1250)
shadow(img, back, 150, 50)
d = ImageDraw.Draw(img)
rr(d, back, 150, (255, 255, 255, 240))
bar = (112, 134, 198, 255)
for (y, width) in [(500, 960), (660, 1040), (820, 700), (980, 880)]:
    rr(d, (360, y, 360 + width, y + 92), 46, bar)

# --- front card: the floating PiP window with the translation ---------------
front = (760, 880, 1860, 1700)
shadow(img, front, 140, 60, offset=(0, 50), alpha=150)
d = ImageDraw.Draw(img)
rr(d, front, 140, (14, 20, 46, 255))
rr(d, (front[0] + 14, front[1] + 14, front[2] - 14, front[3] - 14), 128, (20, 28, 64, 255))
for (y, width, col) in [(1030, 760, (255, 255, 255, 255)),
                        (1190, 860, (84, 222, 255, 255)),
                        (1350, 560, (255, 255, 255, 255))]:
    rr(d, (880, y, 880 + width, y + 96), 48, col)

# --- translate badge ----------------------------------------------------------
cx, cy, r = 1730, 930, 160
shadow(img, (cx - r, cy - r, cx + r, cy + r), r, 24, offset=(0, 20), alpha=130)
d = ImageDraw.Draw(img)
d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 255))
blue = (58, 108, 255, 255)
# right arrow (top)
rr(d, (cx - 85, cy - 52, cx + 40, cy - 22), 15, blue)
d.polygon([(cx + 30, cy - 82), (cx + 30, cy + 8), (cx + 92, cy - 37)], fill=blue)
# left arrow (bottom)
rr(d, (cx - 40, cy + 22, cx + 85, cy + 52), 15, blue)
d.polygon([(cx - 30, cy - 8), (cx - 30, cy + 82), (cx - 92, cy + 37)], fill=blue)

icon = img.resize((1024, 1024), Image.LANCZOS).convert("RGB")   # no alpha: required for app icons

iconset = os.path.join(OUT, "AppIcon.appiconset")
os.makedirs(iconset, exist_ok=True)
icon.save(os.path.join(iconset, "icon-1024.png"))
with open(os.path.join(OUT, "Contents.json"), "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
with open(os.path.join(iconset, "Contents.json"), "w") as f:
    json.dump({
        "images": [{"filename": "icon-1024.png", "idiom": "universal",
                    "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, f, indent=2)
print("wrote", iconset)
