"""Disposable artifacts prove promotion rejects unqualified or changed candidates."""
import base64
import copy
import datetime as dt
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def module(filename):
    spec = importlib.util.spec_from_file_location(filename.replace('-', '_'), ROOT / 'scripts' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


candidate = module('release-candidate.py')
ci = module('require-release-ci.py')
homebrew = module('update-homebrew.py')


@unittest.skipUnless(sys.platform == 'darwin', 'Mach-O tools require macOS')
class ReleaseSymbolTests(unittest.TestCase):
    def test_symbols_must_match_every_shipped_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            symbols = root / 'symbols'
            symbols.mkdir()
            executables = []
            for index in range(2):
                source = root / f'fixture{index}.c'
                source.write_text(f'int main(void) {{ return {index}; }}\n')
                binary = root / f'fixture{index}'
                subprocess.run(['xcrun', 'clang', '-g', str(source), '-o', str(binary)], check=True, capture_output=True)
                executables.append(binary)
            subprocess.run(['xcrun', 'dsymutil', str(executables[0]), '-o', str(symbols / 'fixture0.dSYM')], check=True, capture_output=True)
            candidate.validate_symbols(executables[:1], symbols)
            with self.assertRaisesRegex(ValueError, 'Missing matching dSYM: fixture1'):
                candidate.validate_symbols(executables, symbols)
            subprocess.run(['xcrun', 'dsymutil', str(executables[1]), '-o', str(symbols / 'fixture1.dSYM')], check=True, capture_output=True)
            candidate.validate_symbols(executables, symbols)


class ReleaseCandidateTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = pathlib.Path(temp.name)
        self.signature = base64.b64encode(bytes(64)).decode()
        lock = {'pins': [{'identity': 'airlock', 'state': {'revision': 'b' * 40}}]}
        (self.root / 'Package.resolved').write_text(json.dumps(lock))
        for name in ('Findle-2.0.0.zip', 'Findle-2.0.0.dmg', 'Findle-symbols.zip'):
            (self.root / name).write_bytes(b'disposable artifact')
        (self.root / 'appcast.xml').write_text(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
          <sparkle:version>12</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
          <enclosure url="https://github.com/alexmodrono/Findle/releases/download/v2.0.0/Findle-2.0.0.zip"
            length="19" sparkle:edSignature="{self.signature}"/>
          </item></channel></rss>''')
        self.manifest = dict(version='2.0.0', build='12', source_revision='a' * 40, airlock_revision='b' * 40,
                             minimum_macos='15.0', sparkle_signature=self.signature,
                             created_at='2026-10-01T00:00:00Z',
                             assets={p.name: {'sha256': candidate.digest(p), 'size': p.stat().st_size} for p in self.root.iterdir()})
        self.path = self.root / 'candidate.json'
        self.path.write_text(json.dumps(self.manifest))
        (self.root / 'soak-evidence.json').write_text('{"fixture": "not real release evidence"}')
        self.record = dict(decision='go', source_revision='a' * 40, airlock_revision='b' * 40,
                           candidate_sha256=candidate.digest(self.path), open_p0_p1=0, signed_candidate=True,
                           cycles=100, started_at='2026-10-01T01:00:00Z', finished_at='2026-10-03T01:00:00Z',
                           passed_scenarios=sorted(candidate.SCENARIOS), personal_files_lost=0,
                           personal_files_corrupted=0, reviewer='fixture reviewer',
                           evidence=[dict(path='soak-evidence.json', sha256=candidate.digest(self.root / 'soak-evidence.json'))])

    def qualify(self):
        candidate.validate_qualification(self.record, self.manifest, self.path, self.root,
                                         now=dt.datetime(2026, 10, 4, tzinfo=dt.timezone.utc))

    def test_complete_matching_candidate_and_record(self):
        candidate.validate_manifest(self.manifest, self.root)
        self.qualify()

    def test_modified_archive_is_rejected(self):
        (self.root / 'Findle-2.0.0.zip').write_bytes(b'changed update archive')
        with self.assertRaisesRegex(ValueError, 'checksum'): candidate.validate_manifest(self.manifest, self.root)

    def test_missing_symbols_are_rejected(self):
        (self.root / 'Findle-symbols.zip').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing'): candidate.validate_manifest(self.manifest, self.root)

    def test_unexpected_or_traversing_asset_is_rejected(self):
        self.manifest['assets']['../outside'] = dict(sha256='0' * 64, size=0)
        with self.assertRaisesRegex(ValueError, 'unexpected'): candidate.validate_manifest(self.manifest, self.root)

    def test_appcast_version_or_minimum_os_disagreement_is_rejected(self):
        path = self.root / 'appcast.xml'
        path.write_text(path.read_text().replace('15.0', '14.0'))
        self.manifest['assets']['appcast.xml'] = dict(sha256=candidate.digest(path), size=path.stat().st_size)
        with self.assertRaisesRegex(ValueError, 'minimum OS'): candidate.validate_manifest(self.manifest, self.root)

    def test_dependency_pin_disagreement_is_rejected(self):
        self.manifest['airlock_revision'] = 'c' * 40
        with self.assertRaisesRegex(ValueError, 'Dependency'): candidate.validate_manifest(self.manifest, self.root)

    def test_each_incomplete_qualification_rejects_promotion(self):
        cases = {'decision': 'no-go', 'source_revision': 'c' * 40, 'airlock_revision': 'c' * 40,
                 'candidate_sha256': '0' * 64, 'open_p0_p1': 1, 'signed_candidate': False,
                 'cycles': 99, 'started_at': '2026-10-02T01:00:00Z',
                 'finished_at': '2026-10-05T01:00:00Z', 'passed_scenarios': ['relaunch'],
                 'personal_files_lost': 1, 'personal_files_corrupted': 1, 'reviewer': '', 'evidence': []}
        for key, value in cases.items():
            with self.subTest(key=key):
                original = copy.deepcopy(self.record)
                self.record[key] = value
                with self.assertRaises(ValueError): self.qualify()
                self.record = original

    def test_changed_evidence_is_rejected(self):
        (self.root / 'soak-evidence.json').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'Evidence checksum'): self.qualify()

    def test_evidence_cannot_escape_reviewed_directory(self):
        self.record['evidence'][0]['path'] = '../outside'
        with self.assertRaisesRegex(ValueError, 'outside'): self.qualify()


class ExactRevisionCITests(unittest.TestCase):
    def setUp(self):
        self.run = dict(head_sha='a' * 40, event='push', run_number=12, run_attempt=1,
                        status='completed', conclusion='success', html_url='https://example.invalid/run')

    def test_exact_successful_trusted_revision_is_accepted(self):
        self.assertEqual(ci.check([self.run], 'a' * 40), self.run['html_url'])

    def test_pr_merge_or_different_source_is_not_accepted(self):
        for field, value in [('event', 'pull_request'), ('head_sha', 'b' * 40)]:
            run = dict(self.run, **{field: value})
            with self.subTest(field=field), self.assertRaises(ValueError): ci.check([run], 'a' * 40)

    def test_new_failure_or_incomplete_rerun_overrides_older_success(self):
        for status, conclusion in [('completed', 'failure'), ('in_progress', None), ('completed', 'cancelled')]:
            run = dict(self.run, run_attempt=2, status=status, conclusion=conclusion)
            with self.subTest(status=status, conclusion=conclusion), self.assertRaises(ValueError):
                ci.check([self.run, run], 'a' * 40)


class PublishedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.purl = 'pkg:github/alexmodrono/Findle@v2.0.0'
        self.statement = dict(predicateType='https://in-toto.io/attestation/release/v0.1',
                              predicate=dict(repository='alexmodrono/Findle', tag='v2.0.0', purl=self.purl),
                              subject=[dict(uri=self.purl, digest=dict(sha1='d' * 40)),
                                       dict(name='Findle-2.0.0.zip', digest=dict(sha256='e' * 64))])

    def validate(self):
        candidate.validate_published_release(dict(verificationResult=dict(statement=self.statement)),
                                             'alexmodrono/Findle', 'v2.0.0', 'd' * 40)

    def test_verified_release_binds_the_raw_tag_object(self):
        self.validate()
        self.statement['subject'][0]['digest']['sha1'] = 'a' * 40
        with self.assertRaisesRegex(ValueError, 'tag object'): self.validate()

    def test_different_repository_tag_or_duplicate_identity_is_rejected(self):
        for key, value in [('repository', 'another/repo'), ('tag', 'v1.0.0'), ('purl', 'pkg:github/another/repo@v2.0.0')]:
            original = copy.deepcopy(self.statement)
            self.statement['predicate'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.validate()
            self.statement = original
        self.statement['subject'].append(copy.deepcopy(self.statement['subject'][0]))
        with self.assertRaisesRegex(ValueError, 'tag object'): self.validate()

    def test_latest_never_moves_backwards_but_same_release_can_resume(self):
        self.assertFalse(candidate.can_advance_latest('v2.0.0', 'v2.0.1'))
        self.assertTrue(candidate.can_advance_latest('v2.0.0', 'v2.0.0'))
        self.assertTrue(candidate.can_advance_latest('v10.0.0', 'v2.0.0'))
        with self.assertRaises(ValueError): candidate.can_advance_latest('v2.0.0', 'nightly')


class HomebrewPromotionTests(unittest.TestCase):
    def setUp(self):
        self.cask = '''cask "findle" do
  version "0.2.0"
  sha256 "''' + '0' * 64 + '''"
  url "https://github.com/alexmodrono/Findle/releases/download/v#{version}/Findle-#{version}.zip"
  depends_on macos: ">= :sonoma"
  # Preserve maintainer additions, including uninstall behavior.
  app "Findle.app"
  zap trash: ["~/Library/Containers/es.amodrono.foodle"]
end
'''

    def test_update_preserves_unrelated_cask_content_and_is_idempotent(self):
        result = homebrew.update_cask(self.cask, '2.0.0', 'a' * 64)
        self.assertIn('version "2.0.0"', result)
        self.assertIn('sha256 "' + 'a' * 64 + '"', result)
        self.assertIn('depends_on macos: ">= :sequoia"', result)
        self.assertEqual(result.split('  # Preserve')[1], self.cask.split('  # Preserve')[1])
        self.assertEqual(homebrew.update_cask(result, '2.0.0', 'a' * 64), result)

    def test_unexpected_download_or_layout_requires_review(self):
        for text in [self.cask.replace('alexmodrono/Findle/releases', 'another/repo/releases'),
                     self.cask.replace('  version "0.2.0"', '  version "0.2.0"\n  version "0.3.0"')]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                homebrew.update_cask(text, '2.0.0', 'a' * 64)

    def test_retrying_older_release_cannot_downgrade_homebrew(self):
        current = homebrew.update_cask(self.cask, '2.10.0', 'a' * 64)
        for previous in ('1.99.99', '2.9.0', '2.10.0'):
            checksum = 'b' * 64 if previous == '2.10.0' else 'a' * 64
            with self.subTest(version=previous), self.assertRaises(ValueError):
                homebrew.update_cask(current, previous, checksum)
        newer = homebrew.update_cask(current, '2.11.0', 'b' * 64)
        self.assertIn('version "2.11.0"', newer)
        self.assertEqual(homebrew.update_cask(newer, '2.11.0', 'b' * 64), newer)
