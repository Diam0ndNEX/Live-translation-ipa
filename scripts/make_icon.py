#!/usr/bin/env python3
"""Generate the ScreenLingo screen/translation mark without font or network dependencies."""
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

root = Path(sys.argv[1] if len(sys.argv) > 1 else 'App/Assets.xcassets')
size = 2048
mask = Image.linear_gradient('L').resize((size * 2, size * 2)).rotate(-35, resample=Image.Resampling.BICUBIC)
mask = mask.crop((size // 2, size // 2, size // 2 + size, size // 2 + size))
image = Image.composite(Image.new('RGB', (size, size), '#121c32'), Image.new('RGB', (size, size), '#38215e'), mask).convert('RGBA')
glow = Image.new('RGBA', (size, size))
draw = ImageDraw.Draw(glow)
draw.ellipse((-400, -600, 1700, 1000), fill=(135, 80, 255, 65))
draw.ellipse((1000, 1200, 2500, 2400), fill=(44, 230, 194, 24))
image.alpha_composite(glow.filter(ImageFilter.GaussianBlur(180)))

# A single luminous screen, rather than the old stack of document cards.
shadow = Image.new('RGBA', (size, size))
ImageDraw.Draw(shadow).rounded_rectangle((345, 395, 1703, 1660), radius=270, fill=(0, 0, 0, 170))
image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(80)))
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((290, 320, 1758, 1670), radius=280, fill='#1a2038', outline='#87f4d7', width=70)
# The open lower corner makes the screen read as a speech bubble.
draw.polygon([(1310, 1630), (1550, 1820), (1550, 1570)], fill='#87f4d7')
draw.polygon([(1350, 1570), (1480, 1680), (1480, 1570)], fill='#1a2038')

# Two opposing, generous translation arrows. Readable at home-screen size.
white = '#f5f7ff'
mint = '#87f4d7'
draw.rounded_rectangle((570, 710, 1300, 835), radius=62, fill=white)
draw.polygon([(1220, 565), (1455, 772), (1220, 980)], fill=white)
draw.rounded_rectangle((745, 1095, 1475, 1220), radius=62, fill=mint)
draw.polygon([(830, 950), (595, 1157), (830, 1365)], fill=mint)
# Small screen status indicator is decorative; it never implies a live recording.
draw.rounded_rectangle((860, 1450, 1188, 1494), radius=22, fill='#51566e')

iconset = root / 'AppIcon.appiconset'
iconset.mkdir(parents=True, exist_ok=True)
icon = image.resize((1024, 1024), Image.Resampling.LANCZOS).convert('RGB')
icon.save(iconset / 'icon-1024.png')
(root / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2))
(iconset / 'Contents.json').write_text(json.dumps({
    'images': [{'filename': 'icon-1024.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}],
    'info': {'author': 'xcode', 'version': 1}
}, indent=2))
print('Generated ScreenLingo icon:', iconset)
