#!/usr/bin/env python3
"""Check the shipped Mach-O files, not the build machine's installed tools."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=30)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('arch', choices=['arm64', 'x86_64'])
parser.add_argument('--dmg', type=pathlib.Path)
parser.add_argument('--notarized', choices=['0', '1'], default='0')
args = parser.parse_args()
with (args.app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
minimum = tuple(map(int, info['LSMinimumSystemVersion'].split('.')))
with (args.app / 'Contents/Resources/ToolDownloads.plist').open('rb') as stream:
    downloads = plistlib.load(stream)
whisper_download = downloads.get('whisper-cli', {}).get(args.arch)
if not whisper_download or not whisper_download.get('url', '').startswith('https://') or not re.fullmatch(r'[0-9a-fA-F]{64}', whisper_download.get('sha256', '')):
    raise SystemExit('Missing valid pinned Whisper download configuration for this architecture')
run('codesign', '--verify', '--deep', '--strict', str(args.app))
signature = run('codesign', '-dv', '--verbose=4', str(args.app))
if 'Authority=Developer ID Application:' not in signature or 'runtime' not in signature or 'Timestamp=' not in signature:
    raise SystemExit('App needs timestamped Developer ID signing and hardened runtime')
team = re.search(r'TeamIdentifier=(\S+)', signature).group(1)
binaries = {}
for path in sorted((args.app / 'Contents/MacOS').iterdir()):
    if not path.is_file():
        raise SystemExit(f'Unexpected bundle item: {path.name}')
    run('lipo', '-verify_arch', args.arch, str(path))
    load_commands = run('otool', '-l', str(path))
    versions = re.findall(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos (\d+\.\d+(?:\.\d+)?)', load_commands)
    versions += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+\.\d+(?:\.\d+)?)', load_commands)
    if not versions:
        raise SystemExit(f'No macOS deployment target: {path.name}')
    for version in versions:
        actual = tuple(map(int, version.split('.')))
        if (actual + (0, 0))[:3] > (minimum + (0, 0))[:3]:
            raise SystemExit(f"{path.name} needs macOS {version}, higher than {info['LSMinimumSystemVersion']}")
    dependencies = []
    for line in run('otool', '-L', str(path)).splitlines()[1:]:
        dependency = line.strip().split(' (compatibility')[0]
        if not dependency.startswith(('/usr/lib/', '/System/Library/')):
            raise SystemExit(f'Non-system dependency in {path.name}: {dependency}')
        dependencies.append(dependency)
    for rpath in re.findall(r'\bpath (.+?) \(offset', load_commands):
        if not rpath.startswith(('@', '/usr/lib/', '/System/Library/')):
            raise SystemExit(f'Build-machine rpath in {path.name}: {rpath}')
    child_signature = run('codesign', '-dv', '--verbose=4', str(path))
    if f'TeamIdentifier={team}' not in child_signature or 'Timestamp=' not in child_signature or 'runtime' not in child_signature:
        raise SystemExit(f'Invalid Developer ID/runtime signing: {path.name}')
    if path.name == 'whisper-cli':
        run(str(path.resolve()), '--help')
    elif path.name in ('ffmpeg', 'ffprobe'):
        run(str(path.resolve()), '-version')
    binaries[path.name] = {'sha256': sha256(path), 'minimum_macos': versions[0], 'dependencies': dependencies}
manifest = {'name': info['CFBundleDisplayName'], 'version': info['CFBundleShortVersionString'],
            'bundle_id': info['CFBundleIdentifier'], 'architecture': args.arch,
            'minimum_macos': info['LSMinimumSystemVersion'], 'team_id': team,
            'notarization': 'accepted-and-stapled' if args.notarized == '1' else 'pending',
            'whisper_download': whisper_download, 'binaries': binaries,
            'icon_sha256': sha256(args.app / 'Contents/Resources/AppIcon.icns')}
if info.get('CFBundleIconName'):
    catalog = args.app / 'Contents/Resources/Assets.car'
    assets = json.loads(run('/usr/bin/assetutil', '--info', str(catalog)))
    appearances = {asset.get('Appearance') for asset in assets
                   if asset.get('AssetType') == 'IconImageStack' and asset.get('Name') == info['CFBundleIconName']}
    required = {'NSAppearanceNameAqua', 'NSAppearanceNameDarkAqua', 'ISAppearanceTintable'}
    if not required <= appearances:
        raise SystemExit('Native app icon is missing light, dark, or tinted layers')
    manifest['native_icon'] = {'name': info['CFBundleIconName'], 'assets_sha256': sha256(catalog),
                               'appearances': sorted(appearances)}
if args.notarized == '1':
    run('xcrun', 'stapler', 'validate', str(args.app))
    run('spctl', '--assess', '--type', 'execute', str(args.app))
if args.dmg:
    run('codesign', '--verify', '--strict', str(args.dmg))
    if args.notarized == '1':
        run('xcrun', 'stapler', 'validate', str(args.dmg))
    manifest['dmg'] = {'filename': args.dmg.name, 'bytes': args.dmg.stat().st_size, 'sha256': sha256(args.dmg)}
print(json.dumps(manifest, ensure_ascii=False, indent=2))
