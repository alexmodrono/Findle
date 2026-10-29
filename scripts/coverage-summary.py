#!/usr/bin/env python3
"""Summarize native xccov data and ratchet a reviewed, matching-toolchain baseline."""

import argparse
import json
from pathlib import Path
import sys

MODULES = ("App", "FileProviderExtension", "FindleMCP", "SharedDomain",
           "Networking", "Persistence", "SyncEngine")


def summarize(report):
    files = {}
    for target in report.get("targets", []):
        for file in target.get("files", []):
            path = file["path"].replace("\\", "/")
            marker = "/Sources/"
            if marker in path:
                path = "Sources/" + path.split(marker, 1)[1]
            parts = path.split("/")
            if len(parts) < 3 or parts[0] != "Sources" or parts[1] not in MODULES:
                continue
            executable, covered = file["executableLines"], file["coveredLines"]
            if not isinstance(executable, int) or not 0 <= covered <= executable:
                raise ValueError(f"Invalid line counts for {path}")
            previous = files.get(path, {"executable": 0, "covered": 0})
            # Test targets can source-include an app/helper file. Keep one file,
            # conservatively using the largest denominator and best observed copy;
            # never sum duplicate instrumentation or claim a per-line union.
            files[path] = {"executable": max(executable, previous["executable"]),
                           "covered": max(covered, previous["covered"])}
    modules = {}
    for module in MODULES:
        rows = [row for path, row in files.items() if path.startswith(f"Sources/{module}/")]
        executable = sum(row["executable"] for row in rows)
        covered = sum(row["covered"] for row in rows)
        modules[module] = {"files": len(rows), "executable": executable, "covered": covered,
                           "fraction": covered / executable if executable else None}
    if not files:
        raise ValueError("No Findle source coverage found; check -enableCodeCoverage YES")
    return {"modules": modules, "files": files}


def ratchet(summary, baseline, toolchain, configuration):
    if baseline.get("status") == "unqualified":
        return "UNQUALIFIED — report only; first runner baseline still needs review."
    if baseline.get("status") != "reviewed":
        raise ValueError("Coverage baseline must explicitly be unqualified or reviewed")
    if (baseline.get("version") != 1 or baseline.get("toolchain") != toolchain
            or baseline.get("configuration") != configuration):
        raise ValueError("Reviewed coverage baseline does not match this toolchain/configuration")
    if set(baseline.get("modules", {})) != set(MODULES):
        raise ValueError("Reviewed coverage baseline must include every critical module")
    regressions = []
    for module, previous in baseline["modules"].items():
        value = summary["modules"][module]["fraction"]
        if value is None or not 0 <= previous <= 1 or value + 1e-9 < previous:
            regressions.append(module)
    if regressions:
        raise ValueError("Coverage below reviewed baseline: " + ", ".join(regressions))
    return "Reviewed baseline met for every critical module."


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report")
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--configuration", default="Debug")
    parser.add_argument("--changed-files")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        summary = summarize(json.loads(Path(args.report).read_text()))
        summary["toolchain"] = Path(args.toolchain).read_text().strip()
        summary["configuration"] = args.configuration
        result = 0
        try:
            status = ratchet(summary, json.loads(Path(args.baseline).read_text()),
                             summary["toolchain"], args.configuration)
        except ValueError as error:
            status = str(error)
            result = 1
        summary["baseline_status"] = status
        Path(args.output).write_text(json.dumps(summary, indent=2) + "\n")
        print("## Native Swift coverage\n\n" + status + "\n")
        print("| Module | Instrumented files | Covered / executable lines | Coverage |")
        print("| --- | ---: | ---: | ---: |")
        for module, value in summary["modules"].items():
            percent = f"{value['fraction']:.1%}" if value["fraction"] is not None else "not instrumented"
            print(f"| {module} | {value['files']} | {value['covered']} / {value['executable']} | {percent} |")
        print("\nCounts include instrumented source files only; they do not establish coverage of the entire app. "
              "Duplicate copies use the best covered copy and largest denominator, not a line union.")
        if args.changed_files:
            changed = Path(args.changed_files).read_text().splitlines()
            critical = [path for path in changed if any(path.startswith(f"Sources/{m}/") for m in MODULES)
                        and path.endswith(".swift")]
            if critical:
                print("\nChanged critical source files:\n")
                for path in critical:
                    value = summary["files"].get(path)
                    detail = f"{value['covered']} / {value['executable']} lines" if value else "not instrumented"
                    print(f"- `{path}`: {detail}")
        return result
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Coverage summary failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
