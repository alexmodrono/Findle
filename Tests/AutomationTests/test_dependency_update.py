import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_security_and_coverage import load

updater = load("update-swift-dependency")


class DependencyUpdateTests(unittest.TestCase):
    def setUp(self):
        self.manifest = """name: Findle
packages:
  Airlock:
    url: https://github.com/alexmodrono/Airlock.git
    revision: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.6.0
  MCP:
    url: https://github.com/modelcontextprotocol/swift-sdk
    from: 0.12.1
targets:
  Findle:
    type: application
"""
        self.lock = {"version": 3, "pins": [
            {"identity": "airlock", "state": {"revision": "a" * 40}},
            {"identity": "sparkle", "state": {"version": "2.10.0", "revision": "b" * 40}},
            {"identity": "swift-sdk", "state": {"version": "0.12.1", "revision": "c" * 40}},
        ]}

    def test_real_manifest_constraints_for_all_three_dependencies(self):
        for dependency, requested, original in (("Airlock", "d" * 40, "a" * 40),
                                                 ("Sparkle", "2.10.1", "2.6.0"),
                                                 ("MCP", "0.12.2", "0.12.1")):
            with self.subTest(dependency=dependency):
                actual, _ = updater.proposal(self.manifest, self.lock, dependency, requested)
                self.assertEqual(actual, self.manifest.replace(original, requested))

    def test_breaking_versions_require_explicit_opt_in(self):
        for dependency, requested in (("Sparkle", "3.0.0"), ("MCP", "0.13.0")):
            with self.subTest(dependency=dependency), self.assertRaisesRegex(ValueError, "allow-breaking"):
                updater.proposal(self.manifest, self.lock, dependency, requested)
            updater.proposal(self.manifest, self.lock, dependency, requested, allow_breaking=True)

    def test_rejects_downgrade_nonsemver_branch_and_short_revision(self):
        for dependency, requested in (("Sparkle", "2.9.0"), ("MCP", "latest"),
                                      ("Airlock", "main"), ("Airlock", "abc123")):
            with self.subTest(dependency=dependency, requested=requested), self.assertRaises(ValueError):
                updater.proposal(self.manifest, self.lock, dependency, requested)

    def test_success_updates_both_files_and_resolution_failure_restores_original_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "project.yml"
            lock = root / updater.LOCK
            lock.parent.mkdir(parents=True)
            manifest.write_text(self.manifest)
            lock.write_text(json.dumps(self.lock))
            original_lock = lock.read_bytes()

            def fail(command, **kwargs):
                lock.write_text("partial resolver write")
                raise subprocess.CalledProcessError(1, command)

            with self.assertRaises(subprocess.CalledProcessError):
                updater.perform_update(root, "Sparkle", "2.10.1", runner=fail)
            self.assertEqual(manifest.read_text(), self.manifest)
            self.assertEqual(lock.read_bytes(), original_lock)

            def resolve(command, **kwargs):
                if command[0] == "xcodebuild":
                    self.assertIn("-derivedDataPath", command)
                    self.assertTrue(any(value.startswith("OBJROOT=") for value in command))
                    self.assertTrue(any(value.startswith("SYMROOT=") for value in command))
                    self.assertTrue(any(value.startswith("SHARED_PRECOMPS_DIR=") for value in command))
                    self.lock["pins"][1]["state"]["version"] = "2.10.1"
                    lock.write_text(json.dumps(self.lock))

            result = updater.perform_update(root, "Sparkle", "2.10.1", runner=resolve)
            self.assertIn("from: 2.10.1", manifest.read_text())
            self.assertEqual(result["resolved"]["version"], "2.10.1")

    def test_different_resolver_selection_cannot_be_reported_as_requested_update(self):
        with self.assertRaisesRegex(ValueError, "expected"):
            updater.verify_resolution(self.lock, "Sparkle", "2.10.1")

    def test_discovery_selects_compatible_updates_and_does_not_rollback_airlock(self):
        def fetch(path):
            if path == "repos/alexmodrono/Airlock":
                return {"default_branch": "main"}
            if "/commits/" in path:
                return {"sha": "e" * 40}
            if "/compare/" in path:
                return {"status": "behind"}
            if "sparkle-project" in path:
                return [{"name": value} for value in ["v3.0.0", "2.10.2", "2.10.1", "2.11.0-beta"]]
            return [{"name": value} for value in ["0.13.0", "0.12.3", "0.12.1"]]

        report = updater.discover(self.lock, fetch=fetch)
        self.assertFalse(report["errors"])
        proposals = {entry["dependency"]: entry for entry in report["proposals"]}
        self.assertIsNone(proposals["Airlock"]["candidate"])
        self.assertEqual(proposals["Sparkle"]["candidate"], "2.10.2")
        self.assertEqual(proposals["MCP"]["candidate"], "0.12.3")
        self.assertEqual(proposals["MCP"]["breaking_candidate"], "0.13.0")

    def test_discovery_requires_forward_immutable_airlock_revision(self):
        def fetch(path):
            if path == "repos/alexmodrono/Airlock":
                return {"default_branch": "main"}
            if "/commits/" in path:
                return {"sha": "e" * 40}
            if "/compare/" in path:
                return {"status": "ahead"}
            return [{"name": "2.10.0" if "sparkle-project" in path else "0.12.1"}]

        report = updater.discover(self.lock, fetch=fetch)
        self.assertEqual(report["proposals"][0]["candidate"], "e" * 40)
        self.assertIn("Airlock " + "e" * 40, report["proposals"][0]["apply"])

    def test_network_failure_is_reported_instead_of_no_updates(self):
        def fail(path):
            raise subprocess.TimeoutExpired(["gh", "api", path], 30)

        report = updater.discover(self.lock, fetch=fail)
        self.assertEqual(len(report["errors"]), 3)
        self.assertFalse(report["proposals"])


if __name__ == "__main__":
    unittest.main()
