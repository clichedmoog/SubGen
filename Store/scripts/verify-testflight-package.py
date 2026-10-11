#!/usr/bin/env python3
"""Verify a local Mac store package; keep beta runtime checks explicitly pending."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

import store


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(package):
    config = store.load_config()
    signature = run('pkgutil', '--check-signature', str(package)).decode()
    require('3rd Party Mac Developer Installer:' in signature and
            '(' + config['appleTeam'] + ')' in signature, 'Mac store installer signature/team mismatch')
    with tempfile.TemporaryDirectory(prefix='subtitlegen-store-package-') as directory:
        expanded = Path(directory) / 'expanded'
        run('pkgutil', '--expand-full', str(package), str(expanded))
        apps = list(expanded.rglob('*.app'))
        require(len(apps) == 1, 'Expected one app payload')
        app = apps[0]
        inspected = store.inspect_app(config, app, 'app-store')
        # Beta is the place to finish these live checks. Never turn their flags
        # on from a signed-package check or permit other inspection failures.
        permitted = {'Mac App Store preparation pending: ' + key for key in
                     ('translationBackendVerified', 'securityScopedFilesVerified', 'privacyManifestVerified')}
        require(all(item in permitted for item in inspected['pending']), '\n'.join(inspected['pending']))
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        require(info.get('ITSAppUsesNonExemptEncryption') is False, 'Encryption declaration missing')
        entitlements = plistlib.loads(subprocess.check_output(
            ['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL))
        require(not entitlements.get('com.apple.security.get-task-allow'), 'Development debugging entitlement in export')
        for key in ('com.apple.security.network.client', 'com.apple.security.network.server',
                    'com.apple.security.files.bookmarks.app-scope', 'com.apple.security.files.user-selected.read-write'):
            require(entitlements.get(key) is True, 'Missing app capability: ' + key)
        profile = plistlib.loads(subprocess.check_output(
            ['security', 'cms', '-D', '-i', str(app / 'Contents/embedded.provisionprofile')], stderr=subprocess.DEVNULL))
        require(profile.get('TeamIdentifier') == [config['appleTeam']], 'Provisioning team mismatch')
        require(profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired profile')
        require(not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'), 'Development/direct profile in store export')
        app_id = entitlements.get('com.apple.application-identifier')
        require(app_id == profile['Entitlements'].get('com.apple.application-identifier') and
                app_id.endswith('.' + config['bundleID']), 'Provisioning App ID mismatch')
        resources = app / 'Contents/Resources'
        manifest = plistlib.loads((resources / 'PrivacyInfo.xcprivacy').read_bytes())
        require(manifest.get('NSPrivacyTracking') is False, 'Unexpected tracking manifest')
        require(len(manifest.get('NSPrivacyAccessedAPITypes', [])) >= 3, 'Required-reason manifest declarations missing')
        source_config = json.loads((store.ROOT / 'Store/toolchain/ffmpeg.json').read_text())
        source_folder = resources / 'FFmpegSource'
        require(json.loads((source_folder / 'ffmpeg.json').read_text()) == source_config, 'FFmpeg source identity mismatch')
        require(sha(source_folder / ('ffmpeg-' + source_config['version'] + '.tar.xz')) == source_config['sourceSHA256'], 'FFmpeg source checksum mismatch')
        require(sha(source_folder / 'build-store-ffmpeg.sh') == sha(store.ROOT / 'scripts/build-store-ffmpeg.sh'), 'FFmpeg recipe mismatch')
        require((resources / 'Licenses/FFmpeg-LGPLv2.1.txt').read_bytes() ==
                (source_folder / 'COPYING.LGPLv2.1').read_bytes(), 'FFmpeg license mismatch')
        require((resources / 'Licenses/THIRD-PARTY.txt').read_bytes() ==
                (store.ROOT / 'Store/Resources/THIRD-PARTY.txt').read_bytes(), 'Store tool attribution mismatch')
        for name in ('ffmpeg', 'ffprobe'):
            binary = app / 'Contents/MacOS' / name
            # Sandbox-inherit helpers cannot be launched from an unsandboxed
            # verifier. The signed app host tests their real license/runtime.
            data = binary.read_bytes()
            for flag in (b'--disable-gpl', b'--disable-version3', b'--disable-nonfree', b'--disable-autodetect', b'--enable-indev=lavfi'):
                require(flag in data, 'Expected source-built FFmpeg configuration missing: ' + name)
        require((resources / 'Assets.car').is_file() and (resources / 'AppIcon.icns').is_file(), 'App icons missing')
        inspected['app'] = f'{package.name} payload/{app.name}'
        return {'package': str(package.resolve()), 'packageSHA256': sha(package),
                'verification': 'Mac App Store package/signing/profile/helpers/source verified',
                'app': inspected, 'profileName': profile.get('Name'),
                'profileExpires': profile['ExpirationDate'].isoformat(),
                'ffmpegSource': source_config,
                'pendingRuntimeChecks': ['Live ChatGPT sign-in/inference/refresh/revocation',
                                         'External-folder access and video replacement across app relaunch',
                                         'Visual processing animation in the distributed app',
                                         'Final privacy/provider disclosures before retail review']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.package), indent=2))
