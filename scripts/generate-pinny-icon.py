#!/usr/bin/env python3
"""Generate the Pinny aperture artwork.

Writes:
  Snapzy/PinnyIcon.icon/Assets/Aperture.svg       Icon Composer foreground layer
  Snapzy/Resources/Assets.xcassets/MenubarIcon.imageset/*.png   menu bar template
  build/pinny-icon-preview.png                   flattened 1024 px preview

The glyph is Hugeicons Pro "Aperture" (Solid Rounded, 4.3.4). Hugeicons Pro is licensed
to the account owner: this personal build may bundle it, but do not publish it.
The 24-unit icon is baked into 1024-unit icon space so the SVG needs no transforms.
Rasterising needs `rsvg-convert` (Homebrew librsvg).
"""
import io
import re
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
CENTER = 512.0
DIAMETER = 522.0    # same footprint as the earlier clover glyph
INK = (1.25, 22.75)  # the glyph's extent inside its 24-unit box

APERTURE = [
    'M16.5871 2.27539C15.848 2.47 15.1423 2.74364 14.4796 3.08644C12.6325 4.04202 11.1206 5.53495 10.1562 7.35098'
    'C10.7267 7.12462 11.3486 7.00021 11.9996 7.00021C15.707 7.00021 19.0164 8.69457 21.2276 11.3563'
    'C21.7709 12.0104 22.2479 12.7228 22.6482 13.4829C22.7151 12.9982 22.7496 12.5033 22.7496 12.0002'
    'C22.7496 7.70415 20.2296 3.99667 16.5871 2.27539Z',
    'M1.90234 8.30329C2.18989 8.95722 2.5358 9.5779 2.93317 10.1585C4.06195 11.8076 5.60587 13.133 7.40605 13.9773'
    'C7.14466 13.3708 6.99985 12.7023 6.99985 12C6.99985 8.29264 8.69421 4.98322 11.356 2.77206'
    'C12.01 2.22874 12.7225 1.75173 13.4826 1.35142C12.9979 1.28455 12.5029 1.25 11.9999 1.25'
    'C7.36171 1.25 3.40963 4.18735 1.90234 8.30329Z',
    'M1.25 12.0001C1.25 16.2961 3.77005 20.0036 7.41253 21.7249C8.15161 21.5303 8.85736 21.2566 9.51997 20.9139'
    'C11.3671 19.9583 12.879 18.4653 13.8434 16.6493C13.273 16.8757 12.651 17.0001 12 17.0001'
    'C8.41605 17.0001 5.17773 15.5279 2.8206 13.1486C2.25119 12.5738 1.73319 11.9461 1.27417 11.2734'
    'C1.25814 11.5136 1.25 11.7559 1.25 12.0001Z',
    'M20.9141 14.4796C19.9585 12.6325 18.4655 11.1206 16.6495 10.1562C16.8759 10.7267 17.0003 11.3486 17.0003 11.9996'
    'C17.0003 15.707 15.3059 19.0164 12.6442 21.2276C11.9901 21.7709 11.2777 22.2479 10.5176 22.6482'
    'C11.0022 22.7151 11.4972 22.7496 12.0003 22.7496C16.2963 22.7496 20.0038 20.2296 21.7251 16.5871'
    'C21.5305 15.848 21.2568 15.1423 20.9141 14.4796Z',
]


def baked_paths():
    """Path data mapped from the 24-unit box to 1024-unit icon space (only M/C/Z, all absolute)."""
    scale = DIAMETER / (INK[1] - INK[0])
    mid = (INK[0] + INK[1]) / 2

    def bake(d):
        nums = iter(float(v) for v in re.findall(r'-?\d*\.?\d+', d))
        out = []
        for cmd, args in re.findall(r'([MCZ])([^MCZ]*)', d):
            count = len(re.findall(r'-?\d*\.?\d+', args))
            pts = [next(nums) for _ in range(count)]
            coords = ' '.join(f'{CENTER + (v - mid) * scale:.2f}' for v in pts)
            out.append(cmd + coords)
        return ''.join(out)

    return [bake(d) for d in APERTURE]


def svg_text(fill='#000000', size=1024):
    body = ''.join(f'<path d="{d}"/>' for d in baked_paths())
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
            f'width="{size}" height="{size}"><g fill="{fill}">{body}</g></svg>\n')


def mask(size):
    png = subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size)], input=svg_text().encode(),
                         capture_output=True, check=True).stdout
    return Image.open(io.BytesIO(png)).convert('RGBA').getchannel('A')


def write_svg(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(svg_text())


def write_menubar(folder):
    canvas, lo, hi = 3714, 459, 3255   # keep the 75.28% occupancy MenuBarIconRenderer expects
    glyph = mask(4096)
    glyph = glyph.crop(glyph.getbbox())
    side = hi - lo
    glyph = glyph.resize((side, round(glyph.height * side / glyph.width)), Image.LANCZOS)
    alpha = Image.new('L', (canvas, canvas), 0)
    alpha.paste(glyph, (lo, lo + (side - glyph.height) // 2))
    rgba = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
    rgba.putalpha(alpha)
    for name in ('icon.png', 'icon 1.png', 'icon 2.png'):
        rgba.save(folder / name)


def write_preview(path):
    """Flattened approximation of the final icon (the system adds Liquid Glass)."""
    n = 2048
    s = n / 1024
    img = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    tile = Image.new('L', (n, n), 0)
    ImageDraw.Draw(tile).rounded_rectangle((100 * s, 100 * s, 924 * s, 924 * s), radius=186 * s, fill=255)
    shadow = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    shadow.putalpha(tile.point(lambda v: v * 0.2).filter(ImageFilter.GaussianBlur(22 * s)))
    img.alpha_composite(shadow, (0, int(14 * s)))
    grad = Image.linear_gradient('L').resize((n, n)).point(lambda v: 255 - v * 16 // 255)
    img.alpha_composite(Image.merge('RGBA', (grad, grad, grad, tile)))
    glyph = mask(n)
    gs = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    gs.putalpha(glyph.point(lambda v: v * 0.28).filter(ImageFilter.GaussianBlur(12 * s)))
    img.alpha_composite(gs, (0, int(12 * s)))
    shade = Image.linear_gradient('L').resize((n, n)).point(lambda v: 74 - v * 70 // 255)
    img.alpha_composite(Image.merge('RGBA', (shade, shade, shade, glyph)))
    img.resize((1024, 1024), Image.LANCZOS).save(path)


if __name__ == '__main__':
    write_svg(ROOT / 'Snapzy/PinnyIcon.icon/Assets/Aperture.svg')
    write_menubar(ROOT / 'Snapzy/Resources/Assets.xcassets/MenubarIcon.imageset')
    preview = ROOT.parent / 'build/pinny-icon-preview.png'
    write_preview(preview)
    shutil.copyfile(preview, ROOT / 'banner.png')
    print(preview)

