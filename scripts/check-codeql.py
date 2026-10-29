#!/usr/bin/env python3
"""Fail closed on missing extraction, unreviewed baselines and new high-risk SARIF."""

import argparse
import csv
import datetime
import hashlib
import json
import math
from pathlib import Path
import re
import sys

MODULES = ("App", "FileProviderExtension", "FindleMCP", "SharedDomain",
           "Networking", "Persistence", "SyncEngine")


def extracted_modules(path):
    with Path(path).open(newline="") as source:
        paths = {row[0].replace("\\", "/").removeprefix("./") for row in csv.reader(source) if row}
    counts = {module: sum(p.startswith(f"Sources/{module}/") and p.endswith(".swift")
                          for p in paths) for module in MODULES}
    missing = [module for module, count in counts.items() if not count]
    print(json.dumps({"extracted_swift_files": counts}, indent=2))
    if missing:
        raise ValueError("No extracted declarations in: " + ", ".join(missing))
    return counts


def findings(sarif):
    runs = sarif.get("runs", [])
    if not runs:
        raise ValueError("SARIF has no runs")
    found = {}
    for run in runs:
        invocations = run.get("invocations", [])
        if any(invocation.get("executionSuccessful") is False for invocation in invocations):
            raise ValueError("SARIF reports an unsuccessful analysis")
        driver = run.get("tool", {}).get("driver", {})
        rules = driver.get("rules", [])
        if not rules or "CodeQL" not in driver.get("name", ""):
            raise ValueError("Expected a nonempty CodeQL rule set")
        by_id = {rule["id"]: rule for rule in rules}
        for result in run.get("results", []):
            rule_id = result.get("ruleId")
            rule = by_id.get(rule_id)
            if rule is None:
                raise ValueError(f"Result has no matching rule metadata: {rule_id}")
            severity = rule.get("properties", {}).get("security-severity")
            if severity is None:
                if "security" in rule.get("properties", {}).get("tags", []):
                    raise ValueError(f"Security rule lacks severity metadata: {rule_id}")
                continue  # Quality/diagnostic rules do not have security severity.
            severity = float(severity)
            if not math.isfinite(severity) or not 0 <= severity <= 10:
                raise ValueError(f"Invalid security severity for {rule_id}")
            if severity < 7:
                continue
            location = result.get("locations", [{}])[0].get("physicalLocation", {})
            uri = location.get("artifactLocation", {}).get("uri", "")
            if not uri:
                raise ValueError(f"High-risk result is missing its source location: {rule_id}")
            # CodeQL fingerprints survive line movement. The conservative fallback
            # reopens findings after movement instead of silently accepting them.
            identity = result.get("partialFingerprints") or {
                "region": location.get("region", {}),
                "message": result.get("message", {}),
            }
            fingerprint = hashlib.sha256(json.dumps(
                [rule_id, uri, identity], sort_keys=True, separators=(",", ":")
            ).encode()).hexdigest()
            found[fingerprint] = {"rule": rule_id, "path": uri, "severity": severity}
    return found


def check_baseline(found, baseline, language, today=None):
    if baseline.get("version") != 1:
        raise ValueError("Unsupported CodeQL baseline version")
    entry = baseline.get("languages", {}).get(language, {})
    if entry.get("status") != "reviewed" or not re.fullmatch(r"[0-9a-f]{40}", entry.get("source_sha", "")):
        raise ValueError(f"{language} baseline is unqualified; review the first complete scan before enabling the gate")
    datetime.date.fromisoformat(entry["reviewed_at"])
    today = today or datetime.date.today()
    accepted = entry.get("accepted", {})
    for key, value in accepted.items():
        if not value.get("reason", "").strip() or value["reason"] == "REVIEW REQUIRED":
            raise ValueError(f"Baseline finding {key} has no reviewed justification")
        if datetime.date.fromisoformat(value["expires"]) < today:
            raise ValueError(f"Baseline finding {key} has expired")
    new = {key: value for key, value in found.items() if key not in accepted}
    if new:
        raise ValueError("New high/critical findings:\n" + json.dumps(new, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    extraction = sub.add_parser("extraction")
    extraction.add_argument("csv")
    gate = sub.add_parser("gate")
    gate.add_argument("--sarif", required=True)
    gate.add_argument("--baseline", required=True)
    gate.add_argument("--language", required=True, choices=("swift", "actions"))
    gate.add_argument("--candidate", required=True)
    args = parser.parse_args()
    try:
        if args.command == "extraction":
            extracted_modules(args.csv)
        else:
            found = findings(json.loads(Path(args.sarif).read_text()))
            candidate = {key: dict(value, reason="REVIEW REQUIRED", expires="YYYY-MM-DD")
                         for key, value in found.items()}
            Path(args.candidate).write_text(json.dumps(candidate, indent=2) + "\n")
            check_baseline(found, json.loads(Path(args.baseline).read_text()), args.language)
            print(f"{args.language}: no new high/critical findings ({len(found)} reviewed findings)")
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"CodeQL gate failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
