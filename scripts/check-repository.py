#!/usr/bin/env python3
"""Portable, read-only checks for repository metadata and generated schemes."""

import argparse
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from xml.parsers.expat import ExpatError


MAIN_SUITES = {
    "SharedDomainTests", "NetworkingTests", "FileProviderTests",
    "PersistenceTests", "SyncEngineTests", "FindleMCPTests", "AppInterfaceTests",
}


def annotation(path, message):
    message = str(message).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::error file={path}::{message}", file=sys.stderr)


def check(root, project=None):
    failures = 0
    plist_values = {}
    plists = sorted((root / "Resources").rglob("*.plist"))
    plists += sorted((root / "Resources").rglob("*.entitlements"))
    for path in plists:
        try:
            with path.open("rb") as stream:
                plist_values[path.relative_to(root).as_posix()] = plistlib.load(stream)
            if sys.platform == "darwin":
                subprocess.run(["plutil", "-lint", str(path)], check=True, capture_output=True)
        except (ValueError, OSError, subprocess.CalledProcessError, ExpatError) as error:
            annotation(path.relative_to(root), error)
            failures += 1

    app_path = "Resources/Info/App-Info.plist"
    extension_path = "Resources/Info/FileProvider-Info.plist"
    app = plist_values.get(app_path)
    extension = plist_values.get(extension_path)
    if isinstance(app, dict) and isinstance(extension, dict):
        for key in ("CFBundleShortVersionString", "CFBundleVersion", "FindlePersonalFilesFolderName"):
            if not app.get(key) or app.get(key) != extension.get(key):
                annotation(extension_path, f"{key} must match the app's metadata.")
                failures += 1
        if app.get("SUFeedURL") != "$(FINDLE_APPCAST_URL)":
            annotation(app_path, "SUFeedURL must use FINDLE_APPCAST_URL so Nightly cannot follow the Release feed.")
            failures += 1

    for path in sorted((root / "scripts").glob("*.sh")):
        text = path.read_text()
        first_line = text.splitlines()[0] if text else ""
        shell = "zsh" if "zsh" in first_line else "bash"
        if not shutil.which(shell):
            annotation(path.relative_to(root), f"Install {shell} to check this script.")
            failures += 1
            continue
        result = subprocess.run([shell, "-n", str(path)], capture_output=True, text=True)
        if result.returncode:
            annotation(path.relative_to(root), result.stderr)
            failures += 1
        if re.search(r"Findle-Staging|(?:-configuration|Products/)\s*Staging", text):
            annotation(path.relative_to(root), "Uses the removed Staging scheme/configuration; use Nightly.")
            failures += 1

    board = root / "kanvas.json"
    cli = root / ".agents/skills/kanvas/kanvas.py"
    if not board.is_file() or not cli.is_file():
        annotation("kanvas.json", "The tracked board and bundled Kanvas CLI must both exist.")
        failures += 1
    elif subprocess.run([sys.executable, str(cli), "--board", str(board), "check"]).returncode:
        failures += 1

    if project:
        directory = root / project / "xcshareddata/xcschemes"
        expected = {
            "Findle": MAIN_SUITES,
            "Findle-Nightly": MAIN_SUITES,
            "Findle-OnboardingPreview": {"OnboardingPreviewTests"},
        }
        for name, required in expected.items():
            path = directory / f"{name}.xcscheme"
            try:
                scheme = ET.parse(path)
                actual = {
                    ref.attrib["BlueprintName"]
                    for test in scheme.findall("./TestAction/Testables/TestableReference")
                    if test.attrib.get("skipped") != "YES"
                    for ref in test.findall("./BuildableReference")
                }
                if actual != required:
                    raise ValueError(f"Expected test suites {sorted(required)}, got {sorted(actual)}")
            except (OSError, ET.ParseError, ValueError) as error:
                annotation(path.relative_to(root), error)
                failures += 1
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    parser.add_argument("--generated-project", type=pathlib.Path)
    arguments = parser.parse_args()
    failures = check(arguments.root.resolve(), arguments.generated_project)
    if failures:
        print(f"Repository checks failed: {failures}", file=sys.stderr)
        return 1
    print("Repository metadata, scripts and requested schemes are valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
