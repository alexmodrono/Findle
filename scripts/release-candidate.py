#!/usr/bin/env python3
"""Validate release identity and qualification before any public promotion."""
import argparse
import datetime as dt
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

HEX = re.compile(r"[0-9a-f]{40}")
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
SCENARIOS = {"offline-online", "sleep-wake", "extension-restart", "materialization", "relaunch", "signed-upgrade", "personal-file-hashes", "cpu-memory"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load(path):
    return json.loads(pathlib.Path(path).read_text())


def timestamp(value):
    result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(result.tzinfo is not None, "Timestamps need a timezone")
    return result


def validate_manifest(manifest, directory):
    require(VERSION.fullmatch(manifest["version"]), "Invalid candidate version")
    require(HEX.fullmatch(manifest["source_revision"]), "Invalid source revision")
    require(HEX.fullmatch(manifest["airlock_revision"]), "Invalid Airlock revision")
    require(manifest["minimum_macos"] == "15.0", "Unexpected minimum macOS")
    require(str(manifest["build"]).isdigit(), "Invalid build number")
    expected = {f"Findle-{manifest['version']}.zip", f"Findle-{manifest['version']}.dmg", "Findle-symbols.zip", "appcast.xml", "Package.resolved"}
    require(set(manifest["assets"]) == expected, "Incomplete or unexpected release assets")
    for name, info in manifest["assets"].items():
        path = directory / name
        require(path.is_file() and not path.is_symlink(), f"Missing regular asset: {name}")
        require(path.stat().st_size == info["size"] and digest(path) == info["sha256"], f"Asset checksum mismatch: {name}")
    lock = load(directory / "Package.resolved")
    airlock = next(pin for pin in lock["pins"] if pin["identity"] == "airlock")
    require(airlock["state"]["revision"] == manifest["airlock_revision"], "Dependency revision mismatch")
    root = ET.parse(directory / "appcast.xml").getroot()
    item = root.find("./channel/item")
    require(item is not None, "Missing appcast item")
    ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    require(item.findtext(ns + "version") == str(manifest["build"]), "Appcast build mismatch")
    require(item.findtext(ns + "shortVersionString") == manifest["version"], "Appcast version mismatch")
    require(item.findtext(ns + "minimumSystemVersion") == manifest["minimum_macos"], "Appcast minimum OS mismatch")
    enclosure = item.find("enclosure")
    zip_name = f"Findle-{manifest['version']}.zip"
    require(enclosure is not None, "Missing update enclosure")
    require(enclosure.get("url") == f"https://github.com/alexmodrono/Findle/releases/download/v{manifest['version']}/{zip_name}", "Unexpected update URL")
    require(enclosure.get("length") == str(manifest["assets"][zip_name]["size"]), "Appcast size mismatch")
    require(enclosure.get(ns + "edSignature") == manifest["sparkle_signature"], "Appcast signature mismatch")
    import base64
    require(len(base64.b64decode(manifest["sparkle_signature"], validate=True)) == 64, "Invalid signature encoding")


def validate_qualification(record, manifest, candidate_path, evidence_root, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    require(record["decision"] == "go", "Release has no go decision")
    require(record["source_revision"] == manifest["source_revision"], "Qualification source differs from candidate")
    require(record["airlock_revision"] == manifest["airlock_revision"], "Qualification dependency differs from candidate")
    require(record["candidate_sha256"] == digest(candidate_path), "Qualification covers different artifacts")
    require(record["open_p0_p1"] == 0, "Release blockers remain open")
    require(record["signed_candidate"] is True, "Unsigned tests do not qualify a release")
    require(record["cycles"] >= 100, "Fewer than 100 soak cycles")
    start, end = timestamp(record["started_at"]), timestamp(record["finished_at"])
    require(start >= timestamp(manifest["created_at"]), "Soak predates candidate")
    require(start <= end <= now, "Invalid or future soak dates")
    require((end - start).total_seconds() >= 48 * 3600, "Soak is shorter than 48 hours")
    require(SCENARIOS.issubset(record["passed_scenarios"]), "Required runtime scenarios are missing")
    require(record["personal_files_lost"] == 0 and record["personal_files_corrupted"] == 0, "Personal-file integrity failed")
    require(bool(record["reviewer"].strip()), "Missing maintainer decision")
    require(record["evidence"], "No supporting evidence")
    root = evidence_root.resolve()
    for entry in record["evidence"]:
        path = (root / entry["path"]).resolve()
        require(path.is_relative_to(root) and path.is_file(), "Evidence is outside the reviewed record")
        require(digest(path) == entry["sha256"], "Evidence checksum mismatch")


def binary_uuids(path):
    result = subprocess.run(["xcrun", "dwarfdump", "--uuid", str(path)], check=True, capture_output=True, text=True)
    values = set(re.findall(r"UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", result.stdout))
    require(values, f"No Mach-O UUIDs in {path.name}")
    return values


def validate_symbols(executables, symbols):
    symbol_uuids = set()
    for path in symbols.glob("*.dSYM/Contents/Resources/DWARF/*"):
        symbol_uuids.update(binary_uuids(path))
    require(symbol_uuids, "No release symbols were archived")
    for binary in executables:
        require(binary_uuids(binary).issubset(symbol_uuids), f"Missing matching dSYM: {binary.name}")


def validate_published_release(verification, repository, tag, tag_object):
    statement = verification["verificationResult"]["statement"]
    purl = f"pkg:github/{repository}@{tag}"
    require(statement["predicateType"] == "https://in-toto.io/attestation/release/v0.1", "Wrong release attestation type")
    predicate = statement["predicate"]
    require(predicate["repository"] == repository, "Release repository mismatch")
    require(predicate["tag"] == tag and predicate["purl"] == purl, "Release tag mismatch")
    subjects = [subject for subject in statement["subject"] if subject.get("uri") == purl]
    require(len(subjects) == 1 and subjects[0]["digest"].get("sha1") == tag_object, "Release tag object mismatch")


def can_advance_latest(candidate_tag, current_tag):
    require(candidate_tag.startswith("v") and VERSION.fullmatch(candidate_tag[1:]), "Invalid candidate tag")
    require(current_tag.startswith("v") and VERSION.fullmatch(current_tag[1:]), "Unexpected latest release version; review required")
    return tuple(map(int, candidate_tag[1:].split("."))) >= tuple(map(int, current_tag[1:].split(".")))


def validate_app(app, version, build, revision, team, symbols):
    require(VERSION.fullmatch(version), "Invalid release version")
    require(HEX.fullmatch(revision), "Invalid source revision")
    owned = [app, app / "Contents/PlugIns/FindleFileProvider.appex"]
    owned += [app / f"Contents/Frameworks/{name}.framework" for name in
              ("SharedDomain", "FindleNetworking", "FindlePersistence", "FindleSyncEngine")]
    infos = []
    for bundle in owned:
        path = bundle / "Contents/Info.plist"
        if not path.exists():
            path = bundle / "Resources/Info.plist"
        with open(path, "rb") as stream:
            info = plistlib.load(stream)
        require(info["CFBundleShortVersionString"] == version and info["CFBundleVersion"] == build, f"Version mismatch in {bundle.name}")
        infos.append(info)
    require(infos[0]["CFBundleIdentifier"] == "es.amodrono.findle", "Wrong application channel")
    require(infos[1]["CFBundleIdentifier"] == "es.amodrono.findle.file-provider", "Wrong extension channel")
    require(infos[0]["LSMinimumSystemVersion"] == "15.0", "App minimum macOS differs from release metadata")
    require(infos[0]["FindleSourceRevision"] == revision, "App source revision mismatch")
    executables = []
    for bundle, info in zip(owned, infos):
        binary = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
        if not binary.exists():
            binary = bundle / info["CFBundleExecutable"]
        executables.append(binary)
    executables.append(app / "Contents/MacOS/FindleMCP")
    validate_symbols(executables, symbols)
    for binary in owned + [app / "Contents/MacOS/FindleMCP"]:
        require(binary.exists(), f"Missing signed code: {binary.name}")
        subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True, capture_output=True)
        detail = subprocess.run(["codesign", "-d", "--verbose=4", str(binary)], check=True, capture_output=True, text=True).stderr
        require(f"TeamIdentifier={team}" in detail.splitlines(), f"Signing team mismatch: {binary.name}")
        require("runtime" in detail, f"Hardened runtime missing: {binary.name}")
    entitlements = []
    for bundle in owned[:2]:
        raw = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(bundle)], check=True, capture_output=True).stdout
        ent = plistlib.loads(raw)
        require(not ent.get("com.apple.security.get-task-allow", False), "Debug entitlement in release")
        require(ent.get("com.apple.security.application-groups") == ["group.es.amodrono.findle"], "App Group mismatch")
        require(ent.get("keychain-access-groups") == [f"{team}.es.amodrono.findle"], "Keychain group mismatch")
        entitlements.append(ent)
    require(entitlements[1].get("com.apple.security.app-sandbox") is True, "Provider sandbox missing")
    require(entitlements[1].get("com.apple.security.network.client") is True, "Provider networking entitlement missing")


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    app = commands.add_parser("app")
    for arg in ("app", "version", "build", "revision", "team", "symbols"):
        app.add_argument("--" + arg, required=True)
    manifest = commands.add_parser("manifest")
    for arg in ("directory", "version", "build", "revision", "signature"):
        manifest.add_argument("--" + arg, required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("directory", type=pathlib.Path)
    verify.add_argument("--qualification", type=pathlib.Path)
    verify.add_argument("--evidence-root", type=pathlib.Path, default=pathlib.Path("."))
    published = commands.add_parser("published")
    for arg in ("verification", "repository", "tag", "tag-object"):
        published.add_argument("--" + arg, required=True)
    latest = commands.add_parser("latest")
    latest.add_argument("candidate_tag")
    latest.add_argument("current_tag")
    args = parser.parse_args()
    if args.command == "app":
        validate_app(pathlib.Path(args.app), args.version, args.build, args.revision, args.team, pathlib.Path(args.symbols))
    elif args.command == "published":
        validate_published_release(load(args.verification), args.repository, args.tag, args.tag_object)
    elif args.command == "latest":
        print("true" if can_advance_latest(args.candidate_tag, args.current_tag) else "false")
        return
    elif args.command == "manifest":
        root = pathlib.Path(args.directory)
        lock = load(root / "Package.resolved")
        revision = next(p for p in lock["pins"] if p["identity"] == "airlock")["state"]["revision"]
        names = [f"Findle-{args.version}.zip", f"Findle-{args.version}.dmg", "Findle-symbols.zip", "appcast.xml", "Package.resolved"]
        manifest = dict(version=args.version, build=args.build, source_revision=args.revision,
                        airlock_revision=revision, minimum_macos="15.0", sparkle_signature=args.signature,
                        created_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                        assets={name: dict(sha256=digest(root/name), size=(root/name).stat().st_size) for name in names})
        validate_manifest(manifest, root)
        (root / "candidate.json").write_text(json.dumps(manifest, indent=2) + "\n")
    else:
        manifest = load(args.directory / "candidate.json")
        validate_manifest(manifest, args.directory)
        if args.qualification:
            validate_qualification(load(args.qualification), manifest, args.directory / "candidate.json", args.evidence_root)
    print("Release validation passed")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, StopIteration, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release validation failed: {error}") from error
