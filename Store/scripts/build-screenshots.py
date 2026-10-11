#!/usr/bin/env python3
"""Compose English Mac listing screenshots from real app-window captures."""
import argparse
import hashlib
import json
from io import BytesIO
from pathlib import Path
from PIL import Image, ImageCms, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SIZES = {'1280x800': (1280, 800), '1440x900': (1440, 900),
         '2560x1600': (2560, 1600), '2880x1800': (2880, 1800)}


def compose(capture, item, size):
    width, height = size
    with Image.open(capture) as original:
        original.load()
        profile = original.info.get('icc_profile')
        rgba = original.convert('RGBA')
        if profile:
            rgb = ImageCms.profileToProfile(original.convert('RGB'),
                ImageCms.ImageCmsProfile(BytesIO(profile)), ImageCms.createProfile('sRGB'), outputMode='RGB')
            rgb.putalpha(rgba.getchannel('A'))
            rgba = rgb
    canvas = Image.new('RGB', size, (15, 22, 35))
    draw = ImageDraw.Draw(canvas)
    scale = width / 2560
    for text, y, points, colour in ((item['headline'], 85, 78, '#F3F7FF'),
                                    (item['detail'], 190, 39, '#B7CCF5')):
        font = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', round(points * scale))
        bounds = draw.textbbox((0, 0), text, font=font)
        if bounds[2] - bounds[0] > width - round(160 * scale):
            raise ValueError('Headline exceeds the canvas; shorten canonical copy')
        draw.text(((width - (bounds[2] - bounds[0])) / 2 - bounds[0], round(y * scale)),
                  text, font=font, fill=colour)
    top, margin = round(300 * scale), round(65 * scale)
    factor = min((width - 2 * margin) / rgba.width, (height - top - margin) / rgba.height)
    shot = rgba.resize((round(rgba.width * factor), round(rgba.height * factor)), Image.Resampling.LANCZOS)
    canvas.paste(shot, ((width - shot.width) // 2, top + (height - top - margin - shot.height) // 2), shot)
    return canvas


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--size', choices=SIZES, default='2560x1600')
    args = parser.parse_args()
    out = args.output.expanduser().resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error('Keep raw captures and generated assets outside tracked source')
    items = json.loads((ROOT / 'Store/screenshots/headlines.json').read_text())['en-US']
    captures = [(args.captures / item['capture']).resolve() for item in items]
    for path in captures:
        if not path.is_file():
            parser.error('Missing real app-window capture: ' + str(path))
    out.mkdir(parents=True, exist_ok=False)
    thumbnails, manifest = [], []
    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
    for index, (item, capture) in enumerate(zip(items, captures), 1):
        rendered = compose(capture, item, SIZES[args.size])
        target = out / f'{index:02d}.jpg'
        rendered.save(target, quality=95, subsampling=0, icc_profile=srgb)
        thumbnail = rendered.copy()
        thumbnail.thumbnail((640, 400))
        thumbnails.append(thumbnail)
        manifest.append({'file': target.name, 'dimensions': list(rendered.size), 'locale': 'en-US',
                         'capture': str(capture), 'captureSHA256': hashlib.sha256(capture.read_bytes()).hexdigest(),
                         'sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
    contact = Image.new('RGB', (640 * len(thumbnails), 400), (15, 22, 35))
    for index, thumbnail in enumerate(thumbnails):
        contact.paste(thumbnail, (640 * index, 0))
    contact.save(out / 'contact-sheet.png')
    (out / 'manifest.json').write_text(json.dumps({'platform': 'macOS', 'files': manifest,
        'visualReview': 'pending', 'consoleUpload': 'not-uploaded'}, indent=2) + '\n')
    print(out)


if __name__ == '__main__':
    main()
