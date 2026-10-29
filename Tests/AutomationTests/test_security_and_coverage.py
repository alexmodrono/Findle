import datetime
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


security = load("check-codeql")
coverage = load("coverage-summary")


class SecurityGateTests(unittest.TestCase):
    def setUp(self):
        self.sarif = {"runs": [{"tool": {"driver": {"name": "CodeQL", "rules": [
            {"id": "swift/test", "properties": {"security-severity": "8.1"}}
        ]}}, "results": [{"ruleId": "swift/test", "partialFingerprints": {"primaryLocationLineHash": "stable"},
                         "locations": [{"physicalLocation": {"artifactLocation": {"uri": "Sources/App/Test.swift"},
                                                               "region": {"startLine": 1}}}]}]}]}
        self.baseline = {"version": 1, "languages": {"swift": {
            "status": "reviewed", "source_sha": "a" * 40, "reviewed_at": "2026-10-29", "accepted": {}}}}

    def test_initial_scan_is_not_silently_accepted(self):
        with self.assertRaisesRegex(ValueError, "unqualified"):
            security.check_baseline({}, {"version": 1, "languages": {}}, "swift")

    def test_known_bad_fixture_fails_gate(self):
        with self.assertRaisesRegex(ValueError, "New high/critical"):
            security.check_baseline(security.findings(self.sarif), self.baseline, "swift")

    def test_reviewed_finding_survives_line_movement_but_new_rule_fails(self):
        found = security.findings(self.sarif)
        self.baseline["languages"]["swift"]["accepted"] = {
            key: {"reason": "Test-only fixture", "expires": "2099-01-01"} for key in found}
        self.sarif["runs"][0]["results"][0]["locations"][0]["physicalLocation"]["region"]["startLine"] = 20
        security.check_baseline(security.findings(self.sarif), self.baseline, "swift")
        self.sarif["runs"][0]["results"][0]["partialFingerprints"]["primaryLocationLineHash"] = "new"
        with self.assertRaises(ValueError):
            security.check_baseline(security.findings(self.sarif), self.baseline, "swift")

    def test_expired_acceptance_is_not_a_permanent_suppression(self):
        self.baseline["languages"]["swift"]["accepted"] = {"old": {"reason": "Review", "expires": "2020-01-01"}}
        with self.assertRaisesRegex(ValueError, "expired"):
            security.check_baseline({}, self.baseline, "swift", today=datetime.date(2026, 10, 29))

    def test_empty_or_incomplete_sarif_is_rejected(self):
        for sarif in ({}, {"runs": [{}]}, {"runs": [{"invocations": [{"executionSuccessful": False}]}]}):
            with self.subTest(sarif=sarif), self.assertRaises(ValueError):
                security.findings(sarif)

    def test_medium_findings_remain_reported_but_do_not_block(self):
        self.sarif["runs"][0]["tool"]["driver"]["rules"][0]["properties"]["security-severity"] = "6.9"
        self.assertEqual(security.findings(self.sarif), {})

    def test_security_metadata_cannot_silently_disable_gate(self):
        rule = self.sarif["runs"][0]["tool"]["driver"]["rules"][0]
        for properties in ({"tags": ["security"]}, {"security-severity": "NaN"},
                           {"security-severity": "11"}):
            rule["properties"] = properties
            with self.subTest(properties=properties), self.assertRaises(ValueError):
                security.findings(self.sarif)

    def test_all_product_modules_must_have_extracted_declarations(self):
        with tempfile.TemporaryDirectory() as directory:
            csv = Path(directory) / "files.csv"
            csv.write_text("path\n" + "\n".join(f"Sources/{name}/Example.swift" for name in security.MODULES))
            self.assertEqual(set(security.extracted_modules(csv)), set(security.MODULES))
            csv.write_text("path\nSources/App/Only.swift\n")
            with self.assertRaisesRegex(ValueError, "FileProviderExtension"):
                security.extracted_modules(csv)
            csv.write_text("path\n" + "\n".join(f"../Sources/{name}/Outside.swift" for name in security.MODULES))
            with self.assertRaisesRegex(ValueError, "App"):
                security.extracted_modules(csv)


class CoverageGateTests(unittest.TestCase):
    def test_deduplicates_source_included_in_multiple_targets(self):
        row = {"path": "/tmp/project/Sources/SyncEngine/Engine.swift", "coveredLines": 5, "executableLines": 10}
        other = dict(row, coveredLines=7)
        result = coverage.summarize({"targets": [{"files": [row]}, {"files": [other]}]})
        self.assertEqual(result["modules"]["SyncEngine"], {"files": 1, "covered": 7, "executable": 10, "fraction": .7})

    def test_no_coverage_is_an_error_not_zero_percent_success(self):
        with self.assertRaisesRegex(ValueError, "No Findle"):
            coverage.summarize({"targets": []})

    def test_unmeasured_baseline_remains_visibly_advisory(self):
        self.assertIn("UNQUALIFIED", coverage.ratchet({}, {"status": "unqualified"}, "toolchain", "Debug"))

    def test_unknown_baseline_status_cannot_disable_the_ratchet(self):
        with self.assertRaisesRegex(ValueError, "explicitly"):
            coverage.ratchet({}, {"status": "revieewed"}, "toolchain", "Debug")

    def test_reviewed_baseline_rejects_regression_missing_module_and_toolchain_drift(self):
        summary = {"modules": {module: {"fraction": .6} for module in coverage.MODULES}}
        baseline = {"version": 1, "status": "reviewed", "toolchain": "Xcode", "configuration": "Debug",
                    "modules": {module: .6 for module in coverage.MODULES}}
        coverage.ratchet(summary, baseline, "Xcode", "Debug")
        with self.assertRaisesRegex(ValueError, "toolchain"):
            coverage.ratchet(summary, baseline, "Different", "Debug")
        for fraction in (.59, None):
            summary["modules"]["SyncEngine"]["fraction"] = fraction
            with self.assertRaisesRegex(ValueError, "SyncEngine"):
                coverage.ratchet(summary, baseline, "Xcode", "Debug")


if __name__ == "__main__":
    unittest.main()
