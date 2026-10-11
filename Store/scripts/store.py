#!/usr/bin/env python3
"""Prepare local release materials and check readiness. Never uploads or publishes."""
import argparse
import hashlib
import json
import plistlib
import re
import shlex
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / 'Store/store.config.json'
LIMITS = {'name': 30, 'subtitle': 30, 'description': 4000,
          'keywords': 100, 'promotionalText': 170}
BUILD_CHECKS = ('selfContainedTools', 'sandboxRuntimeVerified',
                'translationBackendVerified', 'securityScopedFilesVerified',
                'privacyManifestVerified')
REVIEW_CHECKS = ('metadataPersisted', 'screenshotsVerified', 'urlsVerified',
                 'privacyPublished', 'ageRatingVerified', 'contentRightsVerified',
                 'encryptionVerified', 'releaseRuntimeVerified', 'processedBuildSelected')


def load_config():
    return json.loads(CONFIG.read_text())


def draft_errors(c):
    errors = []
    info = plistlib.loads((ROOT / 'SubtitleGen/Resources/Info.plist').read_bytes())
    if c.get('bundleID') != info['CFBundleIdentifier']:
        errors.append('Bundle ID differs from the source Info.plist')
    if c.get('minimumOS') != info['LSMinimumSystemVersion']:
        errors.append('Minimum OS differs from the source Info.plist')
    if c.get('platform') != 'macos' or c.get('architectures') != ['arm64']:
        errors.append('Expected the existing native macOS ARM64 app')
    if not re.fullmatch(r'\d+', c.get('appleID', '')) or not c.get('appleTeam'):
        errors.append('Missing App Store identity or signing team')
    locales = c.get('locales', [])
    if not locales or c.get('primaryLocale') not in locales:
        errors.append('Missing primary locale')
    if set(c.get('appInfo', {})) != set(locales) or set(c.get('listings', {})) != set(locales):
        errors.append('Locale sets disagree with the canonical copy')
    for locale in locales:
        app_info = c.get('appInfo', {}).get(locale, {})
        listing = c.get('listings', {}).get(locale, {})
        for key, limit in LIMITS.items():
            value = (app_info if key in ('name', 'subtitle') else listing).get(key)
            if not isinstance(value, str) or not value.strip() or len(value.encode('utf-16-le')) // 2 > limit:
                errors.append(f'{locale}.{key}: missing, empty or over {limit} UTF-16 units')
            if key == 'keywords' and isinstance(value, str) and len(value.encode('utf-8')) > 100:
                errors.append(f'{locale}.keywords exceeds 100 UTF-8 bytes')
    if c.get('macAppStore', {}).get('releaseMode') not in ('MANUAL', 'AFTER_APPROVAL', 'SCHEDULED'):
        errors.append('Missing or invalid release mode; resolve against the console')
    return errors


def store_build_errors(c):
    errors = []
    store = c['macAppStore']
    project = store.get('projectPath')
    if not project or not (ROOT / project).exists() or not store.get('scheme'):
        errors.append('No configured native Xcode app project/scheme for a Mac App Store archive')
    path = ROOT / store['entitlementsPath']
    entitlements = plistlib.loads(path.read_bytes()) if path.is_file() else {}
    if entitlements.get('com.apple.security.app-sandbox') is not True:
        errors.append('App Sandbox is disabled in the configured entitlements')
    for key in BUILD_CHECKS:
        if store.get('readiness', {}).get(key) is not True:
            errors.append('Mac App Store preparation pending: ' + key)
    if not re.fullmatch(r'\d+(?:\.\d+){0,2}', store.get('version', '')) or not re.fullmatch(r'\d+', store.get('build', '')):
        errors.append('Choose a valid store version/build after checking current ASC builds')
    return errors


def review_errors(c):
    errors = []
    for locale in c['locales']:
        for key in ('supportUrl', 'privacyPolicyUrl'):
            value = c['listings'][locale].get(key)
            if not isinstance(value, str) or not value.startswith('https://'):
                errors.append(f'{locale}.{key}: verified public HTTPS URL missing')
    for key in ('firstName', 'lastName', 'email', 'phone'):
        if key == 'phone' and c['review'].get('contact', {}).get('phoneInConsoleVerified') is True:
            continue
        if not c['review'].get('contact', {}).get(key):
            errors.append('Review contact missing: ' + key)
    if not c.get('copyright'):
        errors.append('Copyright owner/year must be confirmed')
    if not isinstance(c['review'].get('demoAccountRequired'), bool) or c['review'].get('demoAccessVerified') is not True:
        errors.append('Reviewer access/authentication for the final store build is unverified')
    store = c['macAppStore']
    if store.get('readiness', {}).get('distributionArchiveVerified') is not True:
        errors.append('Signed Mac App Store archive/package verification is pending')
    for key in REVIEW_CHECKS:
        if store.get('reviewReadiness', {}).get(key) is not True:
            errors.append('Review preparation pending: ' + key)
    delivery = store.get('delivery', {})
    if (delivery.get('processingStatus') != 'processed' or
        delivery.get('version') != store['version'] or delivery.get('build') != store['build']):
        errors.append('No matching processed Mac App Store version/build; TestFlight membership is not required')
    return errors


def direct_errors(c):
    direct = c['direct']
    app, dmg, manifest = (ROOT / direct[key] for key in ('appPath', 'dmgPath', 'manifestPath'))
    if not all(path.exists() for path in (app, dmg, manifest)):
        return ['Expected local app, DMG or verification manifest is missing']
    result = subprocess.run(['python3', str(ROOT / 'scripts/verify-release.py'), str(app), 'arm64',
                             '--dmg', str(dmg), '--notarized', '1'], capture_output=True, text=True)
    if result.returncode:
        return ['Direct artifact verification failed: ' + (result.stderr.strip() or result.stdout.strip())]
    actual, recorded = json.loads(result.stdout), json.loads(manifest.read_text())
    errors = []
    for key, value in {'bundle_id': c['bundleID'], 'team_id': c['appleTeam'], 'version': direct['version']}.items():
        if actual.get(key) != value:
            errors.append('Direct artifact identity mismatch: ' + key)
    for key in ('binaries', 'dmg', 'icon_sha256', 'native_icon'):
        if actual.get(key) != recorded.get(key):
            errors.append('Direct artifact differs from its recorded manifest: ' + key)
    gatekeeper = subprocess.run(['spctl', '--assess', '--type', 'open', '--context',
                                'context:primary-signature', str(dmg)], capture_output=True, text=True)
    if gatekeeper.returncode:
        errors.append('DMG Gatekeeper assessment failed: ' + gatekeeper.stderr.strip())
    return errors


def readiness(c, stage):
    errors = draft_errors(c)
    if stage == 'direct':
        errors += direct_errors(c)
    if stage in ('store-build', 'review'):
        errors += store_build_errors(c)
    if stage == 'review':
        errors += review_errors(c)
    return errors


def inspect_app(c, path, channel):
    path = path.expanduser().resolve()
    is_archive = path.suffix == '.xcarchive'
    if is_archive:
        apps = list((path / 'Products/Applications').glob('*.app'))
        if len(apps) != 1:
            raise ValueError('Expected one app in the native Mac archive')
        path = apps[0]
    if path.suffix != '.app':
        raise ValueError('Inspect a .app or .xcarchive; a DMG is not a Mac App Store artifact')
    info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(path)], check=True)
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(path)], capture_output=True, text=True, check=True).stderr
    entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)],
                                 capture_output=True, check=True).stdout
    entitlements = plistlib.loads(entitlements) if entitlements else {}
    expected = c['direct'] if channel == 'direct' else c['macAppStore']
    errors = []
    helpers = []
    for key, value in {'CFBundleIdentifier': c['bundleID'], 'CFBundleShortVersionString': expected['version']}.items():
        if info.get(key) != value:
            errors.append('Artifact identity mismatch: ' + key)
    if f'TeamIdentifier={c["appleTeam"]}' not in signature.splitlines():
        errors.append('Artifact signing team differs from the configured app')
    binary = path / 'Contents/MacOS' / info['CFBundleExecutable']
    subprocess.run(['lipo', '-verify_arch', 'arm64', str(binary)], check=True)
    if channel == 'app-store':
        if info.get('CFBundleVersion') != expected['build']:
            errors.append('Artifact build differs from the configured store build')
        if entitlements.get('com.apple.security.app-sandbox') is not True:
            errors.append('Mac App Store artifact is not sandboxed')
        authorities = ('Authority=Apple Distribution:', 'Authority=3rd Party Mac Developer Application:')
        if is_archive:
            # Automatic signing may archive with development signing, then
            # apply distribution signing during the App Store export.
            authorities += ('Authority=Apple Development:', 'Authority=Mac Developer:')
        if not any(line.startswith(authorities)
                   for line in signature.splitlines()):
            errors.append('Mac App Store distribution signature missing; Developer ID is a different channel')
        for name in ('ffmpeg', 'ffprobe', 'whisper-cli'):
            helper = path / 'Contents/MacOS' / name
            if not helper.is_file():
                errors.append('Required bundled media tool missing: ' + name)
                continue
            subprocess.run(['codesign', '--verify', '--strict', str(helper)], check=True)
            subprocess.run(['lipo', '-verify_arch', 'arm64', str(helper)], check=True)
            tool_signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(helper)],
                                            capture_output=True, text=True, check=True).stderr
            tool_entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(helper)],
                                               capture_output=True, check=True).stdout
            tool_entitlements = plistlib.loads(tool_entitlements) if tool_entitlements else {}
            errors += helper_errors(c, name, tool_signature, tool_entitlements)
            dependencies = subprocess.run(['otool', '-L', str(helper)], capture_output=True,
                                          text=True, check=True).stdout.splitlines()[1:]
            if any(not line.strip().startswith(('/usr/lib/', '/System/Library/')) for line in dependencies):
                errors.append('Bundled tool depends on an external library: ' + name)
            helpers.append({'name': name, 'entitlements': tool_entitlements,
                            'sha256': hashlib.sha256(helper.read_bytes()).hexdigest()})
        if not (path / 'Contents/Resources/PrivacyInfo.xcprivacy').is_file():
            errors.append('App privacy manifest missing from the built bundle')
        errors += store_build_errors(c)
    elif 'Authority=Developer ID Application:' not in signature:
        errors.append('Direct-distribution Developer ID signature missing')
    return {'channel': channel, 'stage': 'archive-needs-export-verification' if is_archive else 'app', 'app': str(path),
            'identity': {key: info.get(key) for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion')},
            'executableSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'sandboxEnabled': entitlements.get('com.apple.security.app-sandbox') is True,
            'bundledTools': helpers,
            'privacyManifests': [str(p.relative_to(path)) for p in path.rglob('PrivacyInfo.xcprivacy')],
            'pending': errors}


def helper_errors(c, name, signature, entitlements):
    errors = []
    if entitlements != {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}:
        errors.append('Bundled tool must have sandbox + inherit entitlements only: ' + name)
    lines = signature.splitlines()
    if f'TeamIdentifier={c["appleTeam"]}' not in lines:
        errors.append('Bundled tool signing team mismatch: ' + name)
    if f'Identifier={c["bundleID"]}.{name}' not in lines:
        errors.append('Bundled tool signing identifier mismatch: ' + name)
    if not any(line.startswith('CodeDirectory ') and '(runtime)' in line for line in lines):
        errors.append('Bundled tool hardened runtime missing: ' + name)
    return errors


def write_copy(c, out):
    for locale in c['locales']:
        directory = out / locale
        directory.mkdir(parents=True)
        for key, value in {**c['appInfo'][locale], **c['listings'][locale]}.items():
            if isinstance(value, str):
                (directory / (key + '.txt')).write_text(value + '\n')
    (out / 'review-notes-draft.txt').write_text(c['review']['notes'] + '\n')


def plan(c, channel, output):
    if channel == 'direct':
        return '\n'.join([
            '#!/bin/bash', 'set -euo pipefail', 'cd ' + shlex.quote(str(ROOT)),
            '# Builds and notarizes locally. Public publication is a separate step.',
            'VERSION=' + shlex.quote(c['direct']['version']) + ' bash scripts/build-dmg.sh',
            'python3 Store/scripts/store.py check --stage direct', ''])
    errors = readiness(c, 'store-build')
    if errors:
        raise ValueError('\n'.join(errors))
    store = c['macAppStore']
    archive = output / 'SubGen.xcarchive'
    options = output / 'ExportOptions.plist'
    return '\n'.join([
        '#!/bin/bash', 'set -euo pipefail', 'cd ' + shlex.quote(str(ROOT)),
        '# Re-check ASC/TestFlight version/build before executing. Export does not upload.',
        'python3 Store/scripts/store.py check --stage store-build',
        'python3 scripts/prepare-store-tools.py',
        'xcodegen generate',
        shlex.join(['xcodebuild', '-project', store['projectPath'], '-scheme', store['scheme'],
                    '-configuration', 'Release', '-destination', 'generic/platform=macOS',
                    '-archivePath', str(archive), '-derivedDataPath', str(output / 'DerivedData'), 'archive']),
        shlex.join(['python3', 'Store/scripts/store.py', 'inspect', str(archive), '--channel', 'app-store']),
        shlex.join(['python3', 'Store/scripts/store.py', 'export-options', '--output', str(options)]),
        shlex.join(['xcodebuild', '-exportArchive', '-archivePath', str(archive),
                    '-exportOptionsPlist', str(options), '-exportPath', str(output / 'export')]), ''])


def outside_repo(path):
    path = path.expanduser().resolve()
    if path == ROOT or ROOT in path.parents:
        raise ValueError('Keep temporary release artifacts outside tracked source')
    return path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    check = sub.add_parser('check')
    check.add_argument('--stage', choices=['draft', 'direct', 'store-build', 'review'], default='draft')
    sub.add_parser('status')
    prepare = sub.add_parser('prepare', help='Export English copy, fingerprints, plans and remaining work')
    prepare.add_argument('--output', type=Path, required=True)
    copy = sub.add_parser('copy')
    copy.add_argument('--locale', default='en-US')
    copy.add_argument('--field', choices=list(LIMITS) + ['reviewNotes'], required=True)
    build_plan = sub.add_parser('plan', help='Print commands only; no build/upload')
    build_plan.add_argument('--channel', choices=['direct', 'app-store'], required=True)
    build_plan.add_argument('--output', type=Path, required=True)
    export = sub.add_parser('export-options', help='Prepare local Mac App Store export options; never upload')
    export.add_argument('--output', type=Path, required=True)
    inspect = sub.add_parser('inspect', help='Inspect signed native Mac app identity; reject wrong distribution channel')
    inspect.add_argument('path', type=Path)
    inspect.add_argument('--channel', choices=['direct', 'app-store'], required=True)
    args = p.parse_args()
    c = load_config()
    if args.command == 'copy':
        if args.locale not in c['locales']:
            p.error('Locale is not configured for this app')
        value = c['review']['notes'] if args.field == 'reviewNotes' else {**c['appInfo'][args.locale], **c['listings'][args.locale]}[args.field]
        print(value)
        return
    if args.command == 'inspect':
        result = inspect_app(c, args.path, args.channel)
        print(json.dumps(result, indent=2))
        if result['pending']:
            raise SystemExit(1)
        return
    if args.command == 'check':
        errors = readiness(c, args.stage)
        for error in errors:
            print('PENDING: ' + error)
        if errors:
            raise SystemExit(1)
        print('PASS: ' + args.stage + (' local artifact verification' if args.stage == 'direct' else ' recorded preparation; confirm live console/runtime separately'))
        return
    if args.command == 'status':
        print(json.dumps({'app': c['productName'], 'platform': c['platform'],
                          'directPublication': c['direct']['publicationStatus'],
                          'storeReleaseMode': c['macAppStore']['releaseMode'],
                          'stages': {stage: readiness(c, stage) for stage in ('draft', 'store-build', 'review')}}, indent=2))
        return
    out = outside_repo(args.output)
    if args.command == 'plan':
        print(plan(c, args.channel, out))
    elif args.command == 'export-options':
        if out.exists():
            raise ValueError('Export options already exist; preserve previous evidence')
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(plistlib.dumps({'method': 'app-store-connect', 'destination': 'export',
                        'teamID': c['appleTeam'], 'signingStyle': 'automatic',
                        'manageAppVersionAndBuildNumber': False}))
        print(out)
    elif args.command == 'prepare':
        errors = draft_errors(c)
        if errors:
            raise ValueError('\n'.join(errors))
        out.mkdir(parents=True, exist_ok=False)
        write_copy(c, out / 'listing')
        (out / 'direct-plan.sh').write_text(plan(c, 'direct', out / 'direct'))
        if not readiness(c, 'store-build'):
            (out / 'app-store-plan.sh').write_text(plan(c, 'app-store', out / 'mac-app-store'))
        pending = readiness(c, 'review')
        (out / 'store-pending.txt').write_text('\n'.join(pending) + '\n')
        fields = {locale: {key: hashlib.sha256(value.encode()).hexdigest()
                  for key, value in {**c['appInfo'][locale], **c['listings'][locale]}.items()
                  if isinstance(value, str)} for locale in c['locales']}
        (out / 'field-fingerprints.json').write_text(json.dumps(fields, indent=2) + '\n')
        (out / 'config-snapshot.json').write_text(json.dumps(c, ensure_ascii=False, indent=2) + '\n')
        screenshots = json.loads((ROOT / 'Store/screenshots/headlines.json').read_text())
        (out / 'screenshot-plan.json').write_text(json.dumps(screenshots, indent=2) + '\n')
        (out / 'README.txt').write_text('Local release preparation, not persisted ASC metadata.\n'
            'Direct plan rebuilds a local notarized DMG; it does not publish.\n'
            'Read Store/README.md and Store/releases/2026-10-09.md in the repository.\n'
            'Mac App Store: resolve store-pending.txt before archive/upload/review.\n'
            'Release mode currently observed in ASC: ' + c['macAppStore']['releaseMode'] + '\n')
        print(out)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, FileNotFoundError, FileExistsError) as error:
        raise SystemExit(str(error))
