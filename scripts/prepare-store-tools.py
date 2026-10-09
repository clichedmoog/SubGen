#!/usr/bin/env python3
"""Prepare pinned ARM64 helper inputs on the build machine, never at app runtime."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'build/store-tools'
TOOLS = [
    ('whisper-cli', 'https://github.com/clichedmoog/SubGen/releases/download/tools-2026.10.09/whisper-cli-1.8.4-macos14-arm64.zip',
     '7361079edd3fc7204c68053ed1567450e20c27c3ea3f98c258c8c7ea7159a1d2')]
DEST.mkdir(parents=True, exist_ok=True)
inventory = []

def prepared_ffmpeg():
    try:
        expected = json.loads((ROOT / 'Store/toolchain/ffmpeg.json').read_text())
        actual = json.loads((DEST / 'ffmpeg-build.json').read_text())
        if any(actual.get(key) != value for key, value in expected.items()):
            return False
        recipe_hash = hashlib.sha256((ROOT / 'scripts/build-store-ffmpeg.sh').read_bytes()).hexdigest()
        if actual.get('recipeSHA256') != recipe_hash:
            return False
        source = DEST / 'ffmpeg-source' / ('ffmpeg-' + expected['version'] + '.tar.xz')
        if hashlib.sha256(source.read_bytes()).hexdigest() != expected['sourceSHA256']:
            return False
        return all(hashlib.sha256((DEST / name).read_bytes()).hexdigest() == actual['binaries'][name]
                   for name in ('ffmpeg', 'ffprobe'))
    except (OSError, KeyError, ValueError):
        return False

if not prepared_ffmpeg():
    subprocess.run(['bash', str(ROOT / 'scripts/build-store-ffmpeg.sh')], check=True)
if not prepared_ffmpeg():
    raise SystemExit('FFmpeg build/source inventory verification failed')
ffmpeg_inventory = json.loads((DEST / 'ffmpeg-build.json').read_text())
for name in ('ffmpeg', 'ffprobe'):
    target = DEST / name
    license_text = subprocess.check_output([str(target), '-L'], stderr=subprocess.STDOUT, text=True)
    if 'GNU Lesser General Public License' not in ' '.join(license_text.split()):
        raise SystemExit('Expected LGPL FFmpeg build: ' + name)
    inventory.append({'name': name, 'inputSHA256': ffmpeg_inventory['binaries'][name],
                      'sourceURL': ffmpeg_inventory['sourceURL'], 'sourceSHA256': ffmpeg_inventory['sourceSHA256'],
                      'recipeSHA256': ffmpeg_inventory['recipeSHA256']})
for name, url, expected in TOOLS:
    target = DEST / name
    if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != expected:
        with tempfile.TemporaryDirectory(prefix='subtitlegen-store-tools-') as directory:
            archive = Path(directory) / 'download.zip'
            subprocess.run(['curl', '-fL', '--connect-timeout', '20', '--max-time', '300', '--retry', '2', url, '-o', str(archive)], check=True)
            with zipfile.ZipFile(archive) as z:
                candidates = [p for p in z.namelist() if Path(p).name == name and not p.startswith('__MACOSX/')]
                if len(candidates) != 1:
                    raise SystemExit('Ambiguous helper archive: ' + name)
                data = z.read(candidates[0])
            if hashlib.sha256(data).hexdigest() != expected:
                raise SystemExit('Pinned input checksum mismatch: ' + name)
            staged = DEST / (name + '.partial')
            staged.write_bytes(data)
            staged.chmod(0o755)
            os.replace(staged, target)
    inventory.append({'name': name, 'inputSHA256': expected, 'sourceURL': url})
for item in inventory:
    target = DEST / item['name']
    subprocess.run(['lipo', '-verify_arch', 'arm64', str(target)], check=True)
    deps = subprocess.check_output(['otool', '-L', str(target)], text=True).splitlines()[1:]
    for line in deps:
        dep = line.strip().split(' (compatibility')[0]
        if not dep.startswith(('/usr/lib/', '/System/Library/')):
            raise SystemExit('Non-system helper dependency: ' + dep)
(DEST / 'inputs.json').write_text(json.dumps(inventory, indent=2) + '\n')
print('Prepared verified build inputs: ' + str(DEST))
