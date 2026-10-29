#!/usr/bin/env python3
"""One-time ciphertext relay. No plaintext output or repository-secret deletion."""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

REPO = "alexmodrono/Findle"
WORKFLOW = ".github/workflows/migrate-release-secrets-once.yml"
BASE = "5a2e7515e3cf70829cfdf393615092e5b5570c78"
NAMES = {
    "APPLE_ID": "release-candidate",
    "APP_PROVISION_PROFILE_BASE64": "release-candidate",
    "CERTIFICATE_P12_BASE64": "release-candidate",
    "CERTIFICATE_PASSWORD": "release-candidate",
    "FILEPROVIDER_PROVISION_PROFILE_BASE64": "release-candidate",
    "NOTARIZATION_PASSWORD": "release-candidate",
    "SPARKLE_PRIVATE_ED_KEY": "release-candidate",
    "TEAM_ID": "release-candidate",
    "HOMEBREW_TAP_TOKEN": "production",
}
REVIEWED_FILES = (WORKFLOW, ".github/secret-migration.json",
                  "scripts/secret-migration.py", "scripts/secret-migration-requirements.txt",
                  "Tests/SecretMigrationTests/test_secret_migration.py")
LIMIT = 1_000_000


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def decoded(text):
    return base64.b64decode(text, validate=True)


def validate_plan(plan):
    require(set(plan) == {"schema", "repository", "base_sha", "destinations", "source_updated_at"}, "plan schema")
    require(plan["schema"] == 1 and plan["repository"] == REPO and plan["base_sha"] == BASE, "plan identity")
    require(set(plan["destinations"]) == set(NAMES.values()), "destination allowlist")
    require(set(plan["source_updated_at"]) == set(NAMES), "source allowlist")
    for key in plan["destinations"].values():
        require(set(key) == {"key_id", "key"} and key["key_id"].isdigit(), "public key metadata")
        require(len(decoded(key["key"])) == 32, "public key length")


def validate_context(context):
    require(set(context) == {"repository", "event", "ref", "sha", "run_id", "attempt"}, "context schema")
    require(context["repository"] == REPO and context["event"] == "workflow_dispatch"
            and context["ref"] == "refs/heads/main", "main-only dispatch")
    require(re.fullmatch(r"[0-9a-f]{40}", context["sha"]) is not None, "revision")
    require(isinstance(context["run_id"], int) and context["run_id"] > 0 and context["attempt"] == 1, "run identity")


def seal(plan, context, values):
    from nacl.public import PublicKey, SealedBox
    validate_plan(plan)
    validate_context(context)
    require(set(values) == set(NAMES), "secret allowlist")
    require(all(isinstance(v, bytes) and 0 < len(v) <= 49152 for v in values.values()), "missing or invalid secret")
    entries = []
    for name, environment in sorted(NAMES.items()):
        key = plan["destinations"][environment]
        encrypted = SealedBox(PublicKey(decoded(key["key"]))).encrypt(values[name])
        entries.append({"name": name, "environment": environment, "key_id": key["key_id"],
                        "encrypted_value": base64.b64encode(encrypted).decode("ascii")})
    return {"schema": 1, "context": context, "entries": entries}


def validate_manifest(plan, manifest, run_id, sha):
    validate_plan(plan)
    require(set(manifest) == {"schema", "context", "entries"} and manifest["schema"] == 1, "manifest schema")
    validate_context(manifest["context"])
    require(manifest["context"]["run_id"] == run_id and manifest["context"]["sha"] == sha, "manifest run binding")
    require(len(manifest["entries"]) == len(NAMES), "entry count")
    seen = set()
    for entry in manifest["entries"]:
        require(set(entry) == {"name", "environment", "key_id", "encrypted_value"}, "entry schema")
        name = entry["name"]
        require(name in NAMES and name not in seen, "entry allowlist")
        seen.add(name)
        environment = NAMES[name]
        require(entry["environment"] == environment and entry["key_id"] == plan["destinations"][environment]["key_id"], "entry key binding")
        require(48 < len(decoded(entry["encrypted_value"])) <= 49200, "ciphertext length")


def validate_provenance(run, artifact, run_id, sha):
    require(run["id"] == run_id and run["run_attempt"] == 1, "run attempt")
    require(run["repository"]["full_name"] == REPO and run["head_repository"]["full_name"] == REPO, "run repository")
    require(run["event"] == "workflow_dispatch" and run["head_branch"] == "main" and run["head_sha"] == sha, "run provenance")
    require(run["path"] == WORKFLOW and run["status"] == "completed" and run["conclusion"] == "success", "workflow result")
    require(artifact["name"] == f"secret-migration-{run_id}-1" and not artifact["expired"], "artifact identity")
    require(artifact["workflow_run"]["id"] == run_id and artifact["workflow_run"]["head_sha"] == sha, "artifact provenance")
    require(0 < artifact["size_in_bytes"] < LIMIT and re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["digest"] or ""), "artifact bounds/digest")


def read_artifact(blob, digest):
    require(len(blob) < LIMIT and "sha256:" + hashlib.sha256(blob).hexdigest() == digest, "artifact integrity")
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        require(archive.namelist() == ["manifest.json"], "artifact content allowlist")
        require(archive.getinfo("manifest.json").file_size < LIMIT, "manifest bounds")
        return json.loads(archive.read("manifest.json"))


def api(path, payload=None, raw=False):
    # Never supply a token in argv; use the operator's existing gh authentication.
    command = ["gh", "api", "--hostname", "github.com", path]
    if payload is not None:
        command += ["--method", "PUT", "--input", "-"]
    result = subprocess.run(command, input=None if payload is None else json.dumps(payload).encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=60)
    require(result.returncode == 0, "GitHub API request failed; no rollback/deletion performed")
    if raw:
        return result.stdout
    return json.loads(result.stdout) if result.stdout else None


def check_destinations(plan):
    for environment, key in plan["destinations"].items():
        live_key = api(f"repos/{REPO}/environments/{environment}/secrets/public-key")
        require(live_key == key, "destination key changed")
        existing = api(f"repos/{REPO}/environments/{environment}/secrets?per_page=100")
        require(existing["total_count"] == len(existing["secrets"]), "incomplete destination listing")
        require(not any(x["name"] in NAMES for x in existing["secrets"]), "refusing existing destination secret")
    sources = api(f"repos/{REPO}/actions/secrets?per_page=100")
    current = {x["name"]: x["updated_at"] for x in sources["secrets"]}
    require(all(current.get(k) == v for k, v in plan["source_updated_at"].items()), "source changed or removed")


def import_ciphertext(root, run_id, sha, apply=False):
    require(re.fullmatch(r"[0-9a-f]{40}", sha) is not None, "expected reviewed revision required")
    plan = json.loads((root / ".github/secret-migration.json").read_text())
    validate_plan(plan)
    require(api(f"repos/{REPO}/git/ref/heads/main")["object"]["sha"] == sha, "main moved; review again")
    for filename in REVIEWED_FILES:
        remote = api(f"repos/{REPO}/contents/{filename}?ref={sha}")
        require(base64.b64decode(remote["content"]) == (root / filename).read_bytes(), "reviewed files differ from executed revision")
    run = api(f"repos/{REPO}/actions/runs/{run_id}")
    listing = api(f"repos/{REPO}/actions/runs/{run_id}/artifacts?per_page=100")
    require(listing["total_count"] == 1 and len(listing["artifacts"]) == 1, "unexpected artifacts")
    artifact = listing["artifacts"][0]
    validate_provenance(run, artifact, run_id, sha)
    blob = api(f"repos/{REPO}/actions/artifacts/{artifact['id']}/zip", raw=True)
    manifest = read_artifact(blob, artifact["digest"])
    validate_manifest(plan, manifest, run_id, sha)
    check_destinations(plan)
    if not apply:
        print("Verified nine ciphertext entries; dry run made no changes.")
        return
    # GitHub offers upsert, not documented atomic create-only semantics.
    # Freeze concurrent environment-secret administration during this operation.
    for entry in manifest["entries"]:
        environment = entry["environment"]
        current_key = api(f"repos/{REPO}/environments/{environment}/secrets/public-key")
        require(current_key == plan["destinations"][environment], "destination key changed during import")
        existing = api(f"repos/{REPO}/environments/{environment}/secrets?per_page=100")
        require(not any(x["name"] == entry["name"] for x in existing["secrets"]), "refusing overwrite")
        api(f"repos/{REPO}/environments/{environment}/secrets/{entry['name']}",
            {"key_id": entry["key_id"], "encrypted_value": entry["encrypted_value"]})
    print("Imported nine environment secrets. Repository originals remain; credential validation is still required.")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    s = sub.add_parser("seal")
    s.add_argument("--output", required=True)
    i = sub.add_parser("import")
    i.add_argument("--run-id", type=int, required=True)
    i.add_argument("--expected-sha", required=True)
    i.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if args.mode == "import":
        import_ciphertext(root, args.run_id, args.expected_sha, args.apply)
        return
    context = {"repository": os.environ["GITHUB_REPOSITORY"], "event": os.environ["GITHUB_EVENT_NAME"],
               "ref": os.environ["GITHUB_REF"], "sha": os.environ["GITHUB_SHA"],
               "run_id": int(os.environ["GITHUB_RUN_ID"]), "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"])}
    values = {name: os.environb.get(("SOURCE_" + name).encode(), b"") for name in NAMES}
    manifest = seal(json.loads((root / ".github/secret-migration.json").read_text()), context, values)
    target = Path(args.output)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with target.open("x") as output:
        json.dump(manifest, output, separators=(",", ":"))
    print("Sealed nine entries; ciphertext artifact only.")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # No exception repr/traceback: secret bytes must never enter diagnostics.
        print("Migration refused or failed. Original repository secrets were not deleted.", file=sys.stderr)
        sys.exit(1)
