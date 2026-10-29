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


def referenced_item(items, reference, label):
    """Resolve SARIF component/descriptor references without mixing rule namespaces."""
    if not isinstance(reference, dict):
        raise ValueError(f"Invalid {label} reference")
    if "index" in reference:
        index = reference["index"]
        if type(index) is not int or not 0 <= index < len(items):
            raise ValueError(f"Invalid {label} index")
        candidates = [items[index]]
    else:
        candidates = items
    identities = {key: reference[key] for key in ("id", "name", "guid") if key in reference}
    if "index" not in reference and not identities:
        raise ValueError(f"Missing {label} reference")
    def matches(item, key, value):
        if not isinstance(value, str) or not value:
            return False
        actual = item.get(key)
        if actual == value:
            return True
        # SARIF 3.52.4 permits one subcategory after the indexed/GUID rule ID.
        if label == "rule" and key == "id" and ("index" in reference or "guid" in reference):
            return isinstance(actual, str) and value.rpartition("/")[0] == actual and bool(value.rpartition("/")[2])
        return False
    candidates = [item for item in candidates
                  if all(matches(item, key, value) for key, value in identities.items())]
    if len(candidates) != 1:
        raise ValueError(f"Missing, ambiguous or inconsistent {label} reference")
    return candidates[0]


def result_rule(result, tool):
    # SARIF 2.1.0 sections 3.27.7, 3.52 and 3.54: a component index
    # addresses tool.extensions; absent toolComponent means tool.driver.
    if not isinstance(result.get("rule", {}), dict):
        raise ValueError("Invalid rule reference")
    reference = dict(result.get("rule", {}))
    for legacy, key in (("ruleId", "id"), ("ruleIndex", "index")):
        if legacy in result:
            if key in reference and reference[key] != result[legacy]:
                raise ValueError(f"Inconsistent {legacy} and rule.{key}")
            reference[key] = result[legacy]
    component = tool["driver"]
    if "toolComponent" in reference:
        component_ref = reference["toolComponent"]
        if not isinstance(component_ref, dict):
            raise ValueError("Invalid tool component reference")
        extensions = tool.get("extensions", [])
        if "index" in component_ref:
            candidates = extensions
        elif "guid" in component_ref:
            candidates = [component, *extensions]
        else:
            # SARIF 3.54.2: even a name-only reference defaults to the driver.
            # A supplied name validates that choice; it never selects a pack.
            candidates = [component]
            component_ref = {**component_ref, "index": 0}
        component = referenced_item(candidates, component_ref, "tool component")
    return referenced_item(component.get("rules", []), reference, "rule")


def findings(sarif, require_full_scan=True):
    if not isinstance(sarif, dict) or sarif.get("version") != "2.1.0":
        raise ValueError("Expected SARIF 2.1.0")
    runs = sarif.get("runs")
    if not isinstance(runs, list) or not runs:
        raise ValueError("SARIF has no runs")
    found = {}
    for run in runs:
        if not isinstance(run, dict):
            raise ValueError("Invalid SARIF run")
        invocations = run.get("invocations")
        if not isinstance(invocations, list) or not invocations or any(
                not isinstance(invocation, dict) or invocation.get("executionSuccessful") is not True
                for invocation in invocations):
            raise ValueError("SARIF does not confirm successful analysis")
        tool = run.get("tool", {})
        if not isinstance(tool, dict) or not isinstance(tool.get("driver"), dict):
            raise ValueError("Expected a CodeQL tool")
        driver = tool.get("driver", {})
        extensions = tool.get("extensions", [])
        if driver.get("name") != "CodeQL" or not isinstance(extensions, list):
            raise ValueError("Expected a CodeQL tool")
        rules = []
        for component in [driver, *extensions]:
            if not isinstance(component, dict) or not isinstance(component.get("rules", []), list):
                raise ValueError("Invalid SARIF tool component rules")
            rules.extend(component.get("rules", []))
        if not rules:
            raise ValueError("Expected a nonempty CodeQL rule set")
        if any(not isinstance(rule, dict) or not isinstance(rule.get("id"), str) or not rule["id"]
               for rule in rules):
            raise ValueError("Invalid SARIF rule descriptor")
        properties = run.get("properties", {})
        if not isinstance(properties, dict):
            raise ValueError("Invalid SARIF run properties")
        if require_full_scan and ("incrementalMode" in properties or any(
                component.get("name") == "codeql-action/pr-diff-range" for component in extensions)):
            raise ValueError("Expected a full CodeQL scan; incremental/diff-filtered analysis cannot qualify the baseline")
        results = run.get("results")
        if not isinstance(results, list):
            raise ValueError("SARIF is missing analysis results")
        for result in results:
            if not isinstance(result, dict):
                raise ValueError("Invalid SARIF result")
            rule = result_rule(result, tool)
            rule_id = result.get("ruleId", result.get("rule", {}).get("id", rule["id"]))
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
