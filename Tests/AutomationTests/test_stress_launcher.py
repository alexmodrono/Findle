import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class StressLauncherTests(unittest.TestCase):
    def run_mode(self, mode, exit_code=0):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "xcodebuild"
            executable.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                "from pathlib import Path\n"
                "Path(os.environ['STRESS_TEST_CAPTURE']).write_text(json.dumps({'arguments':sys.argv[1:],"
                "'seed':os.environ['TEST_RUNNER_FINDLE_STRESS_SEED']}))\n"
                "sys.exit(int(os.environ['STRESS_TEST_EXIT']))\n"
            )
            executable.chmod(0o755)
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                               STRESS_TEST_CAPTURE=str(root / "capture.json"), STRESS_TEST_EXIT=str(exit_code),
                               FINDLE_STRESS_SEED="42")
            environment.pop("GITHUB_STEP_SUMMARY", None)
            result = subprocess.run(["/bin/bash", str(ROOT / "scripts/run-stress.sh"), mode, str(root / "output")],
                                    env=environment, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, exit_code, result.stderr)
            # An expansion failure before a pipeline must never masquerade as a
            # successful run that did not invoke the test runner (Bash 3.2).
            capture = json.loads((root / "capture.json").read_text())
            self.assertEqual(capture["seed"], "42")
            self.assertIn(f"exit_status={exit_code}", (root / "output/run.txt").read_text())
            return capture["arguments"]

    def test_every_mode_invokes_tests_with_exactly_one_or_no_sanitizers(self):
        for mode, thread, address, configuration in (("nightly", "NO", "NO", "Nightly"),
                                                     ("thread", "YES", "NO", "Debug"),
                                                     ("address", "NO", "YES", "Debug")):
            with self.subTest(mode=mode):
                arguments = self.run_mode(mode)
                self.assertEqual(arguments[arguments.index("-enableThreadSanitizer") + 1], thread)
                self.assertEqual(arguments[arguments.index("-enableAddressSanitizer") + 1], address)
                self.assertEqual(arguments[arguments.index("-configuration") + 1], configuration)
                self.assertEqual(arguments[arguments.index("-test-iterations") + 1], "3")
                self.assertIn("-run-tests-until-failure", arguments)
                self.assertNotIn("-retry-tests-on-failure", arguments)

    def test_failed_test_runner_cannot_be_hidden_by_tee(self):
        self.run_mode("nightly", exit_code=42)


if __name__ == "__main__":
    unittest.main()
