#!/usr/bin/env python3
"""ScreenLingo 2.1.0 spec §13.8: one contact sheet per device, readable on a phone.

Reads ui-screenshots/<device>/<variant>/<fixture>.png and writes contact-<device>.jpg next to them.
Rows are fixtures (order from fixtures.txt), columns are Light, Dark, Light AX3, Dark AX3.
A missing screenshot is drawn as a grey box labelled "missing", so gaps are visible.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

VARIANTS = [("light-default", "Light"), ("dark-default", "Dark"), ("light-ax3", "Light AX3"), ("dark-ax3", "Dark AX3")]
THUMB_W = 300
PAD = 20
LABEL_W = 230
HEAD_H = 70


def font(size):
    for path in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
                 "/Library/Fonts/Arial.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def build(device: Path, fixtures: list[str]) -> Path | None:
    shots = list(device.rglob("*.png"))
    if not shots:
        return None
    w, h = Image.open(shots[0]).size
    th = round(h * THUMB_W / w)
    width = LABEL_W + len(VARIANTS) * (THUMB_W + PAD) + PAD
    height = HEAD_H + len(fixtures) * (th + PAD) + PAD
    sheet = Image.new("RGB", (width, height), (245, 245, 247))
    draw = ImageDraw.Draw(sheet)
    big, small = font(30), font(24)
    draw.text((PAD, 18), device.name, fill=(0, 0, 0), font=big)
    for c, (_, title) in enumerate(VARIANTS):
        draw.text((LABEL_W + c * (THUMB_W + PAD), 22), title, fill=(60, 60, 67), font=small)
    for r, fixture in enumerate(fixtures):
        y = HEAD_H + r * (th + PAD)
        draw.text((PAD, y + th // 2 - 12), fixture, fill=(0, 0, 0), font=small)
        for c, (variant, _) in enumerate(VARIANTS):
            x = LABEL_W + c * (THUMB_W + PAD)
            path = device / variant / f"{fixture}.png"
            if path.exists():
                sheet.paste(Image.open(path).convert("RGB").resize((THUMB_W, th), Image.LANCZOS), (x, y))
            else:
                draw.rectangle([x, y, x + THUMB_W, y + th], fill=(200, 200, 204))
                draw.text((x + 20, y + th // 2 - 12), "missing", fill=(90, 90, 96), font=small)
    out = device.parent / f"contact-{device.name}.jpg"
    sheet.save(out, quality=82, optimize=True)
    return out


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "ui-screenshots")
    fixtures = [line.strip() for line in (root / "fixtures.txt").read_text().splitlines() if line.strip()]
    made = [build(d, fixtures) for d in sorted(root.iterdir()) if d.is_dir()]
    made = [m for m in made if m]
    if not made:
        print("No screenshots found", file=sys.stderr)
        return 1
    for m in made:
        print(f"Contact sheet: {m}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
