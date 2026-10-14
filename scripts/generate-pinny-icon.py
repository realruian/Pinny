#!/usr/bin/env python3
"""Generate the Pinny clover artwork.

Writes:
  Snapzy/PinnyIcon.icon/Assets/Clover.svg        Icon Composer foreground layer
  Snapzy/Resources/Assets.xcassets/MenubarIcon.imageset/*.png   menu bar template
  build/pinny-icon-preview.png                   flattened 1024 px preview

The clover is four discs around the centre, separated by an X-shaped gap. Each
petal is its disc clipped to the quadrant between the two gap edges, so the gap
is real empty space (no strokes or masks that would leave a rim).
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
CENTER = 512.0
OFFSET = 128.0      # disc centre distance from the icon centre
RADIUS = 132.0
STEPS = 720


def clip(poly, keep):
    """Sutherland–Hodgman clip of a closed polygon by the half-plane keep(p) >= 0."""
    out = []
    for i, cur in enumerate(poly):
        prev = poly[i - 1]
        cv, pv = keep(cur), keep(prev)
        if cv >= 0:
            if pv < 0:
                out.append(cross(prev, cur, pv, cv))
            out.append(cur)
        elif pv >= 0:
            out.append(cross(prev, cur, pv, cv))
    return out


def cross(a, b, va, vb):
    t = va / (va - vb)
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def petals(gap):
    """Four petal polygons in 1024-unit icon space (y down)."""
    half = gap / 2 * math.sqrt(2)  # gap/2 measured perpendicular to a 45° line
    result = []
    for angle in (-90, 0, 90, 180):  # top, right, bottom, left
        a = math.radians(angle)
        cx, cy = CENTER + OFFSET * math.cos(a), CENTER + OFFSET * math.sin(a)
        disc = [(cx + RADIUS * math.cos(2 * math.pi * k / STEPS),
                 cy + RADIUS * math.sin(2 * math.pi * k / STEPS)) for k in range(STEPS)]
        ux, uy = math.cos(a), math.sin(a)
        # Keep the side of each diagonal that faces this petal's axis.
        for sx, sy in ((1, 1), (1, -1)):
            nx, ny = (sx * ux + sy * uy), (sy * ux + sx * uy)
            sign = 1 if nx * ux + ny * uy > 0 else -1
            nx, ny = nx * sign, ny * sign
            norm = math.hypot(nx, ny)
            disc = clip(disc, lambda p, nx=nx, ny=ny, norm=norm:
                        ((p[0] - CENTER) * nx + (p[1] - CENTER) * ny) / norm - half / math.sqrt(2))
        result.append(disc)
    return result


def svg_path(poly):
    pts = ' '.join(f'{x:.2f} {y:.2f}' for x, y in poly)
    return f'M{pts}Z'


def write_svg(path, gap):
    body = ''.join(f'<path d="{svg_path(p)}"/>' for p in petals(gap))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
                    f'width="1024" height="1024"><g fill="#000000">{body}</g></svg>\n')


def bounds(polys):
    xs = [x for p in polys for x, _ in p]
    ys = [y for p in polys for _, y in p]
    return min(xs), min(ys), max(xs), max(ys)


def write_menubar(folder, gap):
    canvas, lo, hi = 3714, 459, 3255   # keep the 75.28% occupancy MenuBarIconRenderer expects
    polys = petals(gap)
    x0, y0, x1, y1 = bounds(polys)
    scale = (hi - lo) / max(x1 - x0, y1 - y0)
    img = Image.new('L', (canvas, canvas), 0)
    draw = ImageDraw.Draw(img)
    for p in polys:
        draw.polygon([(lo + (x - x0) * scale, lo + (y - y0) * scale) for x, y in p], fill=255)
    rgba = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
    rgba.putalpha(img)
    for name in ('icon.png', 'icon 1.png', 'icon 2.png'):
        rgba.save(folder / name)


def write_preview(path, gap):
    """Flattened approximation of the final icon (the system adds Liquid Glass)."""
    k, n = 2, 2048
    s = n / 1024
    img = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    tile = Image.new('L', (n, n), 0)
    ImageDraw.Draw(tile).rounded_rectangle((100 * s, 100 * s, 924 * s, 924 * s), radius=186 * s, fill=255)
    shadow = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    shadow.putalpha(tile.point(lambda v: v * 0.2).filter(ImageFilter.GaussianBlur(22 * s)))
    img.alpha_composite(shadow, (0, int(14 * s)))
    bg = Image.new('RGBA', (n, n))
    grad = Image.linear_gradient('L').resize((n, n)).point(lambda v: 255 - v * 16 // 255)
    bg = Image.merge('RGBA', (grad, grad, grad, tile))
    img.alpha_composite(bg)
    glyph = Image.new('L', (n, n), 0)
    gd = ImageDraw.Draw(glyph)
    for p in petals(gap):
        gd.polygon([(x * s, y * s) for x, y in p], fill=255)
    gs = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    gs.putalpha(glyph.point(lambda v: v * 0.28).filter(ImageFilter.GaussianBlur(12 * s)))
    img.alpha_composite(gs, (0, int(12 * s)))
    shade = Image.linear_gradient('L').resize((n, n)).point(lambda v: 74 - v * 70 // 255)
    fg = Image.merge('RGBA', (shade, shade, shade, glyph))
    img.alpha_composite(fg)
    img.resize((1024, 1024), Image.LANCZOS).save(path)


if __name__ == '__main__':
    write_svg(ROOT / 'Snapzy/PinnyIcon.icon/Assets/Clover.svg', gap=30)
    write_menubar(ROOT / 'Snapzy/Resources/Assets.xcassets/MenubarIcon.imageset', gap=46)
    preview = ROOT.parent / 'build/pinny-icon-preview.png'
    write_preview(preview, gap=30)
    print(preview)
