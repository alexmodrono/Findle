#!/usr/bin/env python3
"""Update one real XcodeGen dependency and its canonical SwiftPM lock together."""

import argparse
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote

DEPENDENCIES = {"Airlock": "airlock", "Sparkle": "sparkle", "MCP": "swift-sdk"}
REPOSITORIES = {"Airlock": "alexmodrono/Airlock", "Sparkle": "sparkle-project/Sparkle",
                "MCP": "modelcontextprotocol/swift-sdk"}
LOCK = Path("Findle.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")


def version(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("Use a stable semantic version such as 2.10.0")
    return tuple(int(part) for part in value.split("."))


def compatible(selected, previous):
    return selected[0] == previous[0] and (selected[0] != 0 or selected[1] == previous[1])


def github(path):
    result = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True, timeout=30)
    return json.loads(result.stdout)


def discover(lock, fetch=github):
    proposals, errors = [], []
    pins = {pin["identity"]: pin["state"] for pin in lock["pins"]}
    for dependency, identity in DEPENDENCIES.items():
        try:
            current = pins[identity]
            repository = REPOSITORIES[dependency]
            if dependency == "Airlock":
                branch = fetch(f"repos/{repository}")["default_branch"]
                head = fetch(f"repos/{repository}/commits/{quote(branch, safe='')}")["sha"]
                if not re.fullmatch(r"[0-9a-f]{40}", head):
                    raise ValueError("Default branch did not resolve to an immutable SHA")
                comparison = fetch(f"repos/{repository}/compare/{current['revision']}...{head}")
                ahead = comparison["status"] == "ahead"
                proposals.append({"dependency": dependency, "current": current["revision"],
                                  "candidate": head if ahead else None,
                                  "note": ("Review and test the immutable default-branch revision" if ahead
                                           else f"Default branch comparison: {comparison['status']}; no automatic rollback or branch switch")})
                continue
            tags = []
            for page in (1, 2):  # Bounded discovery: at most 200 upstream tags per package.
                entries = fetch(f"repos/{repository}/tags?per_page=100&page={page}")
                tags.extend(entry["name"].removeprefix("v") for entry in entries)
                if len(entries) < 100:
                    break
            stable = [tag for tag in tags if re.fullmatch(r"\d+\.\d+\.\d+", tag)]
            if not stable:
                raise ValueError("No stable semantic version found in the first 200 tags")
            previous = version(current["version"])
            allowed = [tag for tag in stable if version(tag) > previous and compatible(version(tag), previous)]
            latest = max(stable, key=version)
            proposals.append({"dependency": dependency, "current": current["version"],
                              "candidate": max(allowed, key=version) if allowed else None,
                              "latest_stable": latest,
                              "breaking_candidate": latest if version(latest) > previous and not compatible(version(latest), previous) else None,
                              "note": "Major and pre-1.0 minor updates require a separate explicit review"})
        except (KeyError, ValueError, subprocess.SubprocessError) as error:
            errors.append({"dependency": dependency, "error": str(error)})
    for entry in proposals:
        if entry["candidate"]:
            entry["apply"] = f"python3 scripts/update-swift-dependency.py {entry['dependency']} {entry['candidate']}"
        if entry.get("breaking_candidate"):
            entry["breaking_apply"] = (f"python3 scripts/update-swift-dependency.py {entry['dependency']} "
                                       f"{entry['breaking_candidate']} --allow-breaking")
    return {"generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "proposals": proposals, "errors": errors, "discovery_limit": "200 tags per package; default branch only for Airlock"}


def discovery_markdown(report):
    lines = ["## Swift dependency proposals", "", "Read-only discovery; no manifest, lockfile or PR was changed.", ""]
    for entry in report["proposals"]:
        lines.extend([f"### {entry['dependency']}", "", f"Current: `{entry['current']}`. {entry['note']}.", ""])
        if entry.get("apply"):
            lines.extend(["Candidate apply command:", "", "```sh", entry["apply"], "```", ""])
        else:
            lines.extend(["No compatible forward update found.", ""])
        if entry.get("breaking_apply"):
            lines.extend(["A breaking candidate needs explicit review:", "", "```sh", entry["breaking_apply"], "```", ""])
    for error in report["errors"]:
        lines.append(f"Discovery failed for {error['dependency']}: {error['error']}")
    lines.extend(["", "Create at most one draft PR per dependency (three open Swift update PRs total). "
                  "Review the complete lockfile diff and require CI/CodeQL; no automatic merge or approval.", ""])
    return "\n".join(lines)


def proposal(manifest, lock, dependency, requested, allow_breaking=False):
    field = "revision" if dependency == "Airlock" else "from"
    # Limit edits to exactly one package block, preserving all unrelated YAML.
    package_section = re.search(r"(?ms)^packages:\n(.*?)(?=^\S|\Z)", manifest)
    if not package_section:
        raise ValueError("Missing XcodeGen packages section")
    block = re.search(rf"(?ms)^  {re.escape(dependency)}:\n(.*?)(?=^  \S|\Z)", package_section[1])
    if not block:
        raise ValueError(f"Missing package {dependency}")
    constraint = re.search(rf"(?m)^    {field}: ([^\s#]+)(?:[ \t]*#.*)?$", block[1])
    if not constraint:
        raise ValueError(f"Expected a single plain {field} constraint for {dependency}")
    pins = [pin for pin in lock.get("pins", []) if pin["identity"] == DEPENDENCIES[dependency]]
    if len(pins) != 1:
        raise ValueError(f"Expected exactly one resolved pin for {dependency}")
    current = pins[0]["state"]
    if field == "revision":
        if not re.fullmatch(r"[0-9a-f]{40}", requested):
            raise ValueError("Airlock updates require a full immutable lowercase commit SHA")
        if constraint[1] != current["revision"]:
            raise ValueError("Airlock source constraint and resolved revision disagree")
    else:
        selected, previous = version(requested), version(current["version"])
        if selected < previous:
            raise ValueError("Dependency downgrades require a separate reviewed migration")
        breaking = not compatible(selected, previous)
        if breaking and not allow_breaking:
            raise ValueError("Major/pre-1.0 minor updates require explicit --allow-breaking")
    start = package_section.start(1) + block.start(1) + constraint.start(1)
    end = package_section.start(1) + block.start(1) + constraint.end(1)
    updated = manifest[:start] + requested + manifest[end:]
    return updated, {"dependency": dependency, "field": field,
                     "previous_constraint": constraint[1], "requested": requested,
                     "previous_resolved": current}


def verify_resolution(lock, dependency, requested):
    pins = [pin for pin in lock.get("pins", []) if pin["identity"] == DEPENDENCIES[dependency]]
    if len(pins) != 1:
        raise ValueError("Resolver did not produce exactly one requested dependency")
    state = pins[0]["state"]
    field = "revision" if dependency == "Airlock" else "version"
    if state.get(field) != requested:
        raise ValueError(f"Resolver selected {state.get(field)!r}, expected {requested!r}")
    if not re.fullmatch(r"[0-9a-f]{40}", state.get("revision", "")):
        raise ValueError("Resolver did not produce an immutable revision")
    return state


def perform_update(root, dependency, requested, allow_breaking=False, dry_run=False, runner=subprocess.run):
    manifest_path = root / "project.yml"
    lock_path = root / LOCK
    original_manifest = manifest_path.read_bytes()
    original_lock = lock_path.read_bytes()
    updated, summary = proposal(original_manifest.decode(), json.loads(original_lock), dependency,
                                requested, allow_breaking)
    if dry_run:
        return dict(summary, status="preview; neither manifest nor lock changed")
    try:
        manifest_path.write_text(updated)
        runner(["xcodegen", "generate"], cwd=root, check=True, timeout=60)
        with tempfile.TemporaryDirectory(prefix="findle-dependency-resolution-") as temporary:
            runner(["xcodebuild", "-resolvePackageDependencies", "-project", "Findle.xcodeproj",
                    "-scheme", "Findle", "-clonedSourcePackagesDirPath", str(Path(temporary) / "Packages"),
                    "-derivedDataPath", str(Path(temporary) / "DerivedData"),
                    "OBJROOT=" + str(Path(temporary) / "Objects"),
                    "SYMROOT=" + str(Path(temporary) / "Products"),
                    "SHARED_PRECOMPS_DIR=" + str(Path(temporary) / "Precomps")],
                   cwd=root, check=True, timeout=900)
        summary["resolved"] = verify_resolution(json.loads(lock_path.read_text()), dependency, requested)
        summary["status"] = "resolved; review the manifest and complete lockfile diff, then run CI"
        return summary
    except BaseException:
        # Preserve the caller's original dirty bytes on any resolver/generator failure.
        manifest_path.write_bytes(original_manifest)
        lock_path.write_bytes(original_lock)
        # The generated project is disposable and should be regenerated before use.
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dependency", choices=DEPENDENCIES, nargs="?")
    parser.add_argument("requested", nargs="?", help="Stable version, or full commit SHA for Airlock")
    parser.add_argument("--discover", action="store_true", help="Read-only upstream proposal report")
    parser.add_argument("--output", type=Path, help="Directory for JSON and Markdown discovery artifacts")
    parser.add_argument("--allow-breaking", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        if args.discover:
            report = discover(json.loads((args.root / LOCK).read_text()))
            if args.output:
                args.output.mkdir(parents=True, exist_ok=True)
                (args.output / "swift-dependencies.json").write_text(json.dumps(report, indent=2) + "\n")
                (args.output / "swift-dependencies.md").write_text(discovery_markdown(report))
            print(discovery_markdown(report))
            return 1 if report["errors"] else 0
        if not args.dependency or not args.requested:
            parser.error("provide a dependency and requested version/revision, or --discover")
        print(json.dumps(perform_update(args.root, args.dependency, args.requested,
                                        args.allow_breaking, args.dry_run), indent=2))
        return 0
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(f"Dependency update failed: {error}. Regenerate the project before building.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
