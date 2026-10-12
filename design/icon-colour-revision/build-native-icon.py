#!/usr/bin/env python3
"""Map unchanged Opus xhigh foreground shapes to Icon Composer's unmasked canvas."""
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

layers, destination = map(Path, sys.argv[1:])
ET.register_namespace('', 'http://www.w3.org/2000/svg')
assets = destination / 'Assets'
assets.mkdir(parents=True, exist_ok=True)
names = ['1-speech-bubble.svg', '2-glass-bubble.svg', '3-captions.svg']
for prefix, name in zip(('1-', '2-', '3-'), names):
    matches = list(layers.glob(prefix + '*.svg'))
    if len(matches) != 1:
        raise SystemExit(f'Expected exactly one foreground SVG with prefix {prefix}')
    original = ET.parse(matches[0]).getroot()
    if any(element.tag.rsplit('}', 1)[-1] in ('filter', 'mask', 'clipPath') for element in original.iter()):
        raise SystemExit('Native foreground layers must have clean shapes without baked effects')
    root = ET.Element('{http://www.w3.org/2000/svg}svg',
                      {'width': '1024', 'height': '1024', 'viewBox': '0 0 1024 1024'})
    # Original ICNS tile occupies (100,100)-(924,924). Icon Composer supplies
    # the native tile and its outer padding, so only change the coordinate space.
    group = ET.SubElement(root, '{http://www.w3.org/2000/svg}g',
                          {'transform': 'scale(1.2427184466019417) translate(-100 -100)'})
    group.extend(list(original))
    ET.ElementTree(root).write(assets / name, encoding='unicode')

icon = {
    'features': ['refractivity'],
    'fill': {'automatic-gradient': 'extended-srgb:0.30980,0.55686,0.98431,1.00000'},
    'groups': [
        {'name': 'Speech', 'layers': [{'image-name': names[0], 'name': 'Speech'}],
         'refractivity': {'enabled': True, 'strength': 0.15, 'depth': 0.10},
         'shadow': {'kind': 'neutral', 'opacity': 0.18},
         'translucency': {'enabled': True, 'value': 0.15}},
        {'name': 'Glass subtitle', 'layers': [{'image-name': names[1], 'name': 'Glass subtitle'}],
         'blur-material': 0.15,
         'refractivity': {'enabled': True, 'strength': 0.30, 'depth': 0.20},
         'shadow': {'kind': 'neutral', 'opacity': 0.15},
         'translucency': {'enabled': True, 'value': 0.55}},
        {'name': 'Captions', 'layers': [{'image-name': names[2], 'name': 'Captions', 'glass': False}],
         'shadow': {'kind': 'neutral', 'opacity': 0},
         'translucency': {'enabled': False, 'value': 0}}
    ],
    'supported-platforms': {'squares': 'shared'}
}
# Icon Composer stores frontmost groups first, matching sidebar order.
icon['groups'].reverse()
(destination / 'icon.json').write_text(json.dumps(icon, indent=2) + '\n')
print(destination)
