#!/usr/bin/env python3
"""Notarize a signed app using the account already registered in Xcode.

Optional payloads are copied into a temporary submission app. Apple's notary
service also scans nested containers and issues their tickets. That temporary
app is never a distribution build; the original payload files stay in place.
After acceptance, tickets are stapled to DMG/PKG payloads and verified.
"""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--work-dir', type=Path, required=True)
parser.add_argument('--team-id', default='N9LYHMUDKA')
parser.add_argument('--signing-identity', default='Developer ID Application: Myeongseok SEO (N9LYHMUDKA)')
parser.add_argument('--entitlements', type=Path)
parser.add_argument('--payload', type=Path, action='append', default=[])
parser.add_argument('--resume', action='store_true', help='Resume an uploaded archive without submitting again')
parser.add_argument('--wait-seconds', type=int, default=900)
args = parser.parse_args()
app = args.app.resolve()
work = args.work_dir.resolve()
work.mkdir(parents=True, exist_ok=True)
archive = work / 'Submission.xcarchive'
if archive.exists() and not args.resume:
    raise SystemExit('Use a fresh work directory to preserve previous submissions')
if args.resume and not archive.exists():
    raise SystemExit('No existing archive to resume')
if len({path.name for path in args.payload}) != len(args.payload):
    raise SystemExit('Payload filenames must be unique')
for path in args.payload:
    if not path.is_file():
        raise SystemExit(f'Payload does not exist: {path}')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
options = work / 'ExportOptions.plist'
if not args.resume:
    staged = archive / 'Products/Applications' / app.name
    staged.parent.mkdir(parents=True)
    subprocess.run(['ditto', str(app), str(staged)], check=True)
    if args.payload:
        payload_dir = staged / 'Contents/Resources/NotarizationPayloads'
        payload_dir.mkdir()
        for path in args.payload:
            shutil.copy2(path, payload_dir / path.name)
        signing = ['codesign', '--force', '--timestamp', '--options', 'runtime', '--sign', args.signing_identity]
        if args.entitlements:
            signing += ['--entitlements', str(args.entitlements.resolve())]
        subprocess.run(signing + [str(staged)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
    info = plistlib.loads((staged / 'Contents/Info.plist').read_bytes())
    metadata = {'ArchiveVersion': 2, 'CreationDate': datetime.datetime.now(datetime.timezone.utc),
                'Name': info['CFBundleName'], 'SchemeName': info['CFBundleName'],
                'ApplicationProperties': {'ApplicationPath': f'Applications/{app.name}',
                    'CFBundleIdentifier': info['CFBundleIdentifier'],
                    'CFBundleShortVersionString': info['CFBundleShortVersionString'],
                    'CFBundleVersion': info['CFBundleVersion'], 'Team': args.team_id,
                    'SigningIdentity': args.signing_identity}}
    (archive / 'Info.plist').write_bytes(plistlib.dumps(metadata))
    options = work / 'ExportOptions.plist'
    options.write_bytes(plistlib.dumps({'method': 'developer-id', 'destination': 'upload',
        'teamID': args.team_id, 'signingStyle': 'manual', 'signingCertificate': args.signing_identity}))


def xcode(action, log_name, extra):
    with (work / log_name).open('w') as log:
        result = subprocess.run(['xcodebuild', action, '-archivePath', str(archive)] + extra,
                                stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        if action == '-exportNotarizedApp' and 'is processing and not ready for distribution' in (work / log_name).read_text():
            return False
        raise SystemExit(f'Xcode failed ({result.returncode}); see {work / log_name}')
    return True


if not args.resume:
    print('Submitting through the Xcode Developer ID account...', flush=True)
    xcode('-exportArchive', 'upload.log', ['-exportOptionsPlist', str(options), '-exportPath', str(work / 'upload')])
print('Fetching the notarized app and its ticket...', flush=True)
deadline = time.monotonic() + max(0, args.wait_seconds)
while not xcode('-exportNotarizedApp', 'export-notarized.log', ['-exportPath', str(work / 'notarized')]):
    if time.monotonic() >= deadline:
        raise SystemExit('Apple is still processing. Resume this archive later with --resume.')
    print('Apple is processing; checking again in 30 seconds...', flush=True)
    time.sleep(min(30, max(0, deadline - time.monotonic())))
exported = work / 'notarized' / app.name
subprocess.run(['xcrun', 'stapler', 'validate', str(exported)], check=True)
subprocess.run(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(exported)], check=True)
for payload in args.payload:
    if payload.suffix.lower() in ('.dmg', '.pkg'):
        subprocess.run(['xcrun', 'stapler', 'staple', str(payload.resolve())], check=True)
        subprocess.run(['xcrun', 'stapler', 'validate', str(payload.resolve())], check=True)
        if payload.suffix.lower() == '.dmg':
            subprocess.run(['spctl', '--assess', '--type', 'open', '--context',
                            'context:primary-signature', '--verbose=2', str(payload.resolve())], check=True)
archive_info = plistlib.loads((archive / 'Info.plist').read_bytes())
receipt = {'backend': 'xcode', 'app': str(app), 'team_id': args.team_id,
           'status': 'accepted-and-stapled', 'temporary_submission_has_payloads': bool(args.payload),
           'payloads': [str(path.resolve()) for path in args.payload],
           'distributions': archive_info.get('Distributions', [])}
(work / 'receipt.json').write_text(json.dumps(receipt, indent=2, default=str) + '\n')
print(f'Accepted and verified; receipt: {work / "receipt.json"}', flush=True)
