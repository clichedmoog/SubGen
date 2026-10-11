"""Regression checks for release gates and preparation without external writes."""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('store', Path(__file__).with_name('store.py'))
store = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(store)


class StoreWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.config = copy.deepcopy(store.load_config())

    def test_missing_description_cannot_pass_as_valid_copy(self):
        del self.config['listings']['en-US']['description']
        self.assertTrue(any('description' in e for e in store.draft_errors(self.config)))

    def test_extra_locale_requires_canonical_copy(self):
        self.config['locales'].append('ja')
        self.assertTrue(any('Locale sets' in e for e in store.draft_errors(self.config)))

    def test_oversized_keywords_rejected(self):
        self.config['listings']['en-US']['keywords'] = '字幕' * 30
        self.assertTrue(any('UTF-8' in e for e in store.draft_errors(self.config)))

    def test_missing_readiness_entries_are_pending(self):
        self.config['macAppStore']['readiness'] = {}
        errors = store.store_build_errors(self.config)
        for key in store.BUILD_CHECKS:
            self.assertTrue(any(key in e for e in errors), key)

    def test_store_plan_cannot_treat_direct_app_as_store_ready(self):
        self.config['macAppStore']['entitlementsPath'] = 'SubtitleGen/Resources/SubtitleGenerator.entitlements'
        with self.assertRaisesRegex(ValueError, 'App Sandbox'):
            store.plan(self.config, 'app-store', Path('/tmp/subtitlegen-test-plan'))

    def test_archive_plan_does_not_require_a_preexisting_verified_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / 'Example.xcodeproj'
            project.mkdir()
            entitlements = root / 'Store.entitlements'
            entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
            config = self.config['macAppStore']
            config.update(projectPath=str(project), scheme='SubGen', entitlementsPath=str(entitlements))
            config['readiness'].update({key: True for key in store.BUILD_CHECKS})
            config['readiness']['distributionArchiveVerified'] = False
            text = store.plan(self.config, 'app-store', root / 'export')
            self.assertIn('generic/platform=macOS', text)
            self.assertIn('-exportArchive', text)
            self.assertNotIn('destination upload', text)

    def test_retail_processing_does_not_require_a_testflight_group(self):
        c = self.config
        c['review'].update(demoAccountRequired=False, demoAccessVerified=True)
        c['review']['contact'] = dict(firstName='Test', lastName='User', email='review@example.test', phone='+12025550100')
        c['copyright'] = '2026 Test owner'
        for listing in c['listings'].values():
            listing.update(supportUrl='https://example.test/support', privacyPolicyUrl='https://example.test/privacy')
        s = c['macAppStore']
        s['readiness']['distributionArchiveVerified'] = True
        s['reviewReadiness'] = {key: True for key in store.REVIEW_CHECKS}
        s['delivery'].update(version=s['version'], build=s['build'], processingStatus='processed')
        self.assertEqual(store.review_errors(c), [])
        s['delivery']['build'] = '999'
        self.assertTrue(any('matching processed' in e for e in store.review_errors(c)))

    def test_prepare_preserves_previous_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'prepared'
            script = str(Path(store.__file__).resolve())
            args = [sys.executable, script, 'prepare', '--output', str(output)]
            subprocess.run(args, capture_output=True, check=True)
            marker = output / 'do-not-overwrite.txt'
            marker.write_text('previous preparation')
            second = subprocess.run(args, capture_output=True)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual(marker.read_text(), 'previous preparation')
            fields = json.loads((output / 'field-fingerprints.json').read_text())
            self.assertEqual(fields['en-US']['description'], store.hashlib.sha256(
                self.config['listings']['en-US']['description'].encode()).hexdigest())

    def test_review_phone_can_stay_private_when_verified_in_console(self):
        contact = self.config['review']['contact']
        contact.update(phone=None, phoneInConsoleVerified=True)
        self.assertNotIn('Review contact missing: phone', store.review_errors(self.config))
        contact['phoneInConsoleVerified'] = False
        self.assertIn('Review contact missing: phone', store.review_errors(self.config))

    def test_output_inside_source_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'outside tracked source'):
            store.outside_repo(store.ROOT / 'Store/test-output')

    def test_dmg_is_rejected_from_store_inspection(self):
        with self.assertRaisesRegex(ValueError, 'DMG is not a Mac App Store artifact'):
            store.inspect_app(self.config, Path('/tmp/example.dmg'), 'app-store')

    def test_extra_helper_entitlements_and_wrong_identity_are_rejected(self):
        c = self.config
        signature = '\n'.join([f'Identifier={c["bundleID"]}.ffmpeg',
                               f'TeamIdentifier={c["appleTeam"]}', 'CodeDirectory flags=0x10000(runtime)'])
        inherited = {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
        self.assertEqual(store.helper_errors(c, 'ffmpeg', signature, inherited), [])
        for extra in ('com.apple.security.get-task-allow', 'com.apple.security.network.client'):
            self.assertTrue(store.helper_errors(c, 'ffmpeg', signature, {**inherited, extra: True}))
        self.assertTrue(store.helper_errors(c, 'ffprobe', signature, inherited))
        self.assertTrue(store.helper_errors(c, 'ffmpeg', signature.replace(c['appleTeam'], 'OTHER'), inherited))


if __name__ == '__main__':
    unittest.main()
