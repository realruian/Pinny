#!/usr/bin/env python3
"""Generate the inline capture toolbar icons from Hugeicons Pro packages.

Usage: python3 scripts/generate-toolbar-icons.py <dir containing core-stroke-rounded/ and core-solid-rounded/>
Each directory is an unpacked `npm pack @hugeicons-pro/<style>@4.3.4` tarball (package/dist/esm/*Icon.js).
The icon modules are parsed as text, never executed.

Writes Snapzy/Resources/Assets.xcassets/CaptureTool-<key>.imageset (stroke) and, for keys that
switch to solid when selected, CaptureTool-<key>-fill.imageset. Hugeicons Pro is licensed to the
account owner: this personal build may bundle it, but do not publish these SVGs.
"""
import json
import re
import sys
from pathlib import Path

STROKE = 'core-stroke-rounded'
SOLID = 'core-solid-rounded'

# key: (Hugeicons name, how the selected state looks)
#   'swap'   -> stroke normally, solid when selected
#   'fixed'  -> stroke in every state (fill would change the meaning)
#   'solid'  -> solid in every state
#   'filled' -> stroke paths filled in every state
ICONS = {
    # Main toolbar tools
    'selection': ('Cursor01', 'swap'),
    'rectangle': ('RectangleHorizontal', 'fixed'),
    'filledRectangle': ('RectangleHorizontal', 'filled'),
    'oval': ('Circle', 'fixed'),
    'arrow': ('ArrowUpRight03', 'swap'),
    'line': ('Slash', 'swap'),
    'text': ('Text', 'swap'),
    'highlighter': ('Highlighter', 'swap'),
    'blur': ('Grid3x3', 'swap'),
    'spotlight': ('Spotlight', 'swap'),
    'counter': ('OneCircle', 'swap'),
    'watermark': ('Copyright', 'swap'),
    'pencil': ('PencilEdit01', 'swap'),
    # Main toolbar actions
    'scrolling': ('CarouselVertical', 'fixed'),
    'crop': ('Crop', 'swap'),
    'undo': ('Undo03', 'fixed'),
    'redo': ('Redo03', 'fixed'),
    'copy': ('Copy01', 'fixed'),
    'pin': ('Pin', 'fixed'),
    'save': ('Download04', 'fixed'),
    'cancel': ('Cancel01', 'fixed'),
    'overflow': ('ArrowRight01', 'fixed'),
    # Properties bar: segmented pickers (key suffix is the enum rawValue)
    'text-plain': ('TextFont', 'swap'),
    'text-label': ('Label', 'swap'),
    'text-callout': ('BubbleChat', 'swap'),
    'blur-pixelated': ('Grid3x3', 'swap'),
    'blur-gaussian': ('Blur', 'swap'),
    'blur-hexagonal': ('Hexagon', 'swap'),
    'blur-crystallized': ('Diamond02', 'swap'),
    'blur-pointillism': ('CircleDot', 'swap'),
    'blur-halftone': ('MaterialAndTexture', 'swap'),
    'blur-tape': ('Bandage', 'swap'),
    'blur-washi': ('PaintBrush04', 'swap'),
    'arrowstyle-straight': ('ArrowUpRight01', 'swap'),
    'arrowstyle-curvedRight': ('ArrowTurnForward', 'swap'),
    'arrowstyle-curvedLeft': ('ArrowTurnBackward', 'swap'),
    'arrowtype-classic': ('ArrowUpRight01', 'fixed'),
    'arrowtype-tapered': ('ArrowUpRight02', 'solid'),
    'arrowtype-outlined': ('ArrowUpRight02', 'fixed'),
    'bend-primary': ('Redo02', 'swap'),
    'bend-alternate': ('Undo02', 'swap'),
    'endpoint-none': ('MinusSign', 'fixed'),
    'endpoint-arrow': ('Play', 'swap'),
    'endpoint-circle': ('Circle', 'filled'),
    'watermark-single': ('TextAlignCenter', 'swap'),
    'watermark-diagonal': ('Slash', 'swap'),
    'watermark-tiled': ('Grid', 'swap'),
    # Properties bar: slider leading icons and colour controls
    'slider-stroke': ('LineStyle', 'fixed'),
    'slider-size': ('ArrowExpandDiagonal01', 'fixed'),
    'slider-font': ('ALargeSmall', 'fixed'),
    'slider-corners': ('SquareRoundCorner', 'fixed'),
    'slider-opacity': ('Contrast', 'fixed'),
    'slider-rotation': ('RotateClockwise', 'fixed'),
    'properties': ('SlidersHorizontal', 'fixed'),
    'color-dropdown': ('ArrowDown01', 'fixed'),
    'color-none': ('CircleSlash', 'fixed'),
    'color-add': ('PlusSign', 'fixed'),
    'color-drop': ('ArrowDown02', 'fixed'),
    'color-remove': ('CancelCircle', 'solid'),
}

CONTENTS = {
    'images': [{'filename': 'icon.svg', 'idiom': 'universal'}],
    'info': {'author': 'xcode', 'version': 1},
    'properties': {'preserves-vector-representation': True, 'template-rendering-intent': 'template'},
}


def svg(package_root: Path, style: str, name: str, fill_strokes: bool = False) -> str:
    source = (package_root / style / 'package/dist/esm' / f'{name}Icon.js').read_text()
    elements = []
    for tag, body in re.findall(r'\[\s*"(\w+)",\s*\{([^}]*)\}\s*\]', source):
        attrs = {}
        for key, value in re.findall(r'(\w+):\s*"([^"]*)"', body):
            if key == 'key':
                continue
            if value == 'currentColor':
                value = '#000'
            if key == 'strokeWidth':
                value = '1.8'  # 1.5pt at the toolbar's 20pt size
            attrs[re.sub(r'[A-Z]', lambda m: '-' + m.group().lower(), key)] = value
        if fill_strokes and 'stroke' in attrs and 'fill' not in attrs:
            attrs['fill'] = '#000'
        elements.append(f'<{tag} ' + ' '.join(f'{k}="{v}"' for k, v in attrs.items()) + '/>')
    if not elements:
        sys.exit(f'No drawable elements in {style}/{name}')
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">'
            + ''.join(elements) + '</svg>')


def write(assets: Path, asset: str, content: str) -> None:
    folder = assets / f'CaptureTool-{asset}.imageset'
    folder.mkdir(exist_ok=True)
    (folder / 'icon.svg').write_text(content)
    (folder / 'Contents.json').write_text(json.dumps(CONTENTS, indent=2) + '\n')


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    package_root = Path(sys.argv[1])
    assets = Path(__file__).resolve().parents[1] / 'Snapzy/Resources/Assets.xcassets'
    for key, (name, mode) in ICONS.items():
        if mode == 'solid':
            write(assets, key, svg(package_root, SOLID, name))
        else:
            write(assets, key, svg(package_root, STROKE, name, fill_strokes=mode == 'filled'))
        if mode == 'swap':
            write(assets, f'{key}-fill', svg(package_root, SOLID, name))
    print(f'{len(ICONS)} icons, {sum(m == "swap" for _, m in ICONS.values())} with selected variants')


if __name__ == '__main__':
    main()
