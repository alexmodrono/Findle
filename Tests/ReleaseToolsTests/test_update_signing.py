"""Exercise the release signing gate without production keys or Keychain access."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class UpdateSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_dir = tempfile.TemporaryDirectory()
        cls.fixtures = pathlib.Path(cls.fixture_dir.name)
        generator = cls.fixtures / "fixture.swift"
        generator.write_text('''import CryptoKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let data = Data("disposable update archive".utf8)
try data.write(to: root.appendingPathComponent("update.zip"))
try key.signature(for: data).base64EncodedString().write(to: root.appendingPathComponent("signature"), atomically: true, encoding: .utf8)
let plist = ["SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString()]
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
''')
        subprocess.run(["swift", str(generator), str(cls.fixtures)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixture_dir.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = pathlib.Path(self.directory.name)
        for name in ("update.zip", "signature", "Info.plist"):
            shutil.copyfile(self.fixtures / name, self.path / name)
        self.signer = self.path / "signer"
        self.signer.write_text('#!/bin/bash\ncat >/dev/null\ncat "$(dirname "$0")/signature"\n')
        self.signer.chmod(0o700)
        self.outputs = self.path / "outputs"
        self.environment = dict(os.environ, SIGN_UPDATE=str(self.signer),
                                SPARKLE_PRIVATE_ED_KEY="test-only-not-a-key", GITHUB_OUTPUT=str(self.outputs))

    def run_gate(self):
        return subprocess.run(["bash", str(ROOT / "scripts/sign-update.sh"),
                               str(self.path / "update.zip"), str(self.path / "Info.plist")],
                              env=self.environment, capture_output=True, text=True)

    def assert_rejected(self):
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.outputs.exists(), "A rejected archive must publish no outputs")

    def test_valid_signature_emits_verified_metadata(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ed_signature=" + (self.path / "signature").read_text(), self.outputs.read_text())
        self.assertIn("zip_size=" + str((self.path / "update.zip").stat().st_size), self.outputs.read_text())

    def test_empty_signature_is_rejected(self):
        (self.path / "signature").write_text("")
        self.assert_rejected()

    def test_malformed_signature_is_rejected(self):
        (self.path / "signature").write_text("not-base64")
        self.assert_rejected()

    def test_modified_archive_is_rejected(self):
        (self.path / "update.zip").write_bytes(b"different archive")
        self.assert_rejected()

    def test_different_embedded_public_key_is_rejected(self):
        import base64
        (self.path / "Info.plist").write_bytes(plistlib.dumps({"SUPublicEDKey": base64.b64encode(bytes(32)).decode()}))
        self.assert_rejected()

    def test_missing_public_key_is_rejected(self):
        (self.path / "Info.plist").write_bytes(plistlib.dumps({}))
        self.assert_rejected()

    def test_missing_signing_key_is_rejected(self):
        self.environment.pop("SPARKLE_PRIVATE_ED_KEY")
        self.assert_rejected()

    def test_missing_signer_is_rejected(self):
        self.signer.unlink()
        self.assert_rejected()

    def test_failed_signer_is_rejected(self):
        self.signer.write_text("#!/bin/bash\nexit 1\n")
        self.assert_rejected()


if __name__ == "__main__":
    unittest.main()
