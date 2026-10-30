import base64
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import os
import subprocess
import unittest
from unittest.mock import patch
import zipfile
from nacl.public import PrivateKey, SealedBox

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("migration", ROOT / "scripts/secret-migration.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.private = {env: PrivateKey.generate() for env in set(m.NAMES.values())}
        self.plan = {"schema": 1, "repository": m.REPO, "base_sha": m.BASE,
                     "destinations": {e: {"key_id": "123", "key": base64.b64encode(bytes(k.public_key)).decode()} for e, k in self.private.items()},
                     "source_updated_at": {n: "2026-01-01T00:00:00Z" for n in m.NAMES}}
        self.sha = "a" * 40
        self.context = {"repository": m.REPO, "event": "workflow_dispatch", "ref": "refs/heads/main", "sha": self.sha, "run_id": 42, "attempt": 1}
        self.values = {n: ("  DUMMY-" + n + "\nUnicode: ñ🧪\r\n ").encode() for n in m.NAMES}
        self.manifest = m.seal(self.plan, self.context, self.values)
        self.run = {"id": 42, "run_attempt": 1, "repository": {"full_name": m.REPO}, "head_repository": {"full_name": m.REPO},
                    "event": "workflow_dispatch", "head_branch": "main", "head_sha": self.sha,
                    "path": m.WORKFLOW, "status": "completed", "conclusion": "success"}
        b = io.BytesIO()
        with zipfile.ZipFile(b, "w") as z: z.writestr("manifest.json", json.dumps(self.manifest))
        self.blob = b.getvalue()
        self.artifact = {"id": 5, "name": "secret-migration-42-1", "expired": False,
                         "workflow_run": {"id": 42, "head_sha": self.sha}, "size_in_bytes": len(self.blob),
                         "digest": "sha256:" + hashlib.sha256(self.blob).hexdigest()}

    def test_exact_bytes_and_no_plaintext_manifest(self):
        for entry in self.manifest["entries"]:
            clear = SealedBox(self.private[entry["environment"]]).decrypt(m.decoded(entry["encrypted_value"]))
            self.assertEqual(clear, self.values[entry["name"]])
            self.assertNotIn(self.values[entry["name"]], json.dumps(self.manifest).encode())
        m.validate_manifest(self.plan, self.manifest, 42, self.sha)

    def test_distinct_keys_even_with_identical_key_ids(self):
        entry = self.manifest["entries"][0]
        other = next(e for e in self.private if e != entry["environment"])
        with self.assertRaises(Exception): SealedBox(self.private[other]).decrypt(m.decoded(entry["encrypted_value"]))

    def test_missing_empty_extra_and_oversized_secret(self):
        for values in (dict(self.values, APPLE_ID=b""), dict(self.values, APPLE_ID=b"x"*49153), dict(self.values, EXTRA=b"dummy"), {k:v for k,v in self.values.items() if k != "APPLE_ID"}):
            with self.subTest(keys=list(values)):
                with self.assertRaises(ValueError): m.seal(self.plan, self.context, values)

    def test_dispatch_context_restrictions(self):
        for key, value in (("repository", "other/repo"), ("event", "pull_request"), ("ref", "refs/tags/v1"), ("attempt", 2)):
            with self.assertRaises(ValueError): m.seal(self.plan, dict(self.context, **{key:value}), self.values)

    def test_manifest_allowlist_duplicates_bindings(self):
        variants=[]
        for key,value in (("name","UNKNOWN"),("environment","production"),("key_id","999"),("encrypted_value","bad!")):
            d=copy.deepcopy(self.manifest); d["entries"][0][key]=value; variants.append(d)
        d=copy.deepcopy(self.manifest);d["entries"][1]=d["entries"][0];variants.append(d)
        d=copy.deepcopy(self.manifest);d["context"]["sha"]="b"*40;variants.append(d)
        for d in variants:
            with self.assertRaises(ValueError):m.validate_manifest(self.plan,d,42,self.sha)

    def test_run_provenance(self):
        m.validate_provenance(self.run,self.artifact,42,self.sha)
        for key,value in (("event","pull_request"),("run_attempt",2),("head_branch","evil"),("head_sha","b"*40),("path","other.yml"),("conclusion","failure"),("head_repository",{"full_name":"fork/repo"})):
            with self.assertRaises(ValueError):m.validate_provenance(dict(self.run,**{key:value}),self.artifact,42,self.sha)

    def test_artifact_tampering(self):
        self.assertEqual(m.read_artifact(self.blob,self.artifact["digest"]),self.manifest)
        with self.assertRaises(ValueError):m.read_artifact(self.blob+b"tamper",self.artifact["digest"])
        b=io.BytesIO()
        with zipfile.ZipFile(b,"w") as z:z.writestr("../manifest.json",json.dumps(self.manifest))
        blob=b.getvalue()
        with self.assertRaises(ValueError):m.read_artifact(blob,"sha256:"+hashlib.sha256(blob).hexdigest())
        for key,value in (("expired",True),("name","wrong"),("workflow_run",{"id":9,"head_sha":self.sha})):
            with self.assertRaises(ValueError):m.validate_provenance(self.run,dict(self.artifact,**{key:value}),42,self.sha)

    def fake_api(self, calls, mode=None):
        def api(path,payload=None,raw=False):
            calls.append((path,payload))
            if payload is not None:return None
            if "/git/ref/" in path:return {"object":{"sha":self.sha}}
            if "/contents/" in path:
                name=path.split("/contents/",1)[1].split("?",1)[0]
                data=(ROOT/name).read_bytes() if name!=".github/secret-migration.json" else json.dumps(self.plan).encode()
                return {"content":base64.b64encode(b"changed" if mode=="reviewed" else data).decode()}
            if path.endswith("/runs/42"):return self.run
            if "/runs/42/artifacts" in path:return {"total_count":1,"artifacts":[self.artifact]}
            if path.endswith("/artifacts/5/zip"):return self.blob
            if "/environments/" in path:
                env=path.split("/environments/",1)[1].split("/",1)[0]
                put_happened=any(p is not None for _,p in calls)
                if path.endswith("public-key"):
                    if mode=="key" or (mode=="key_after_put" and put_happened):
                        return dict(self.plan["destinations"][env],key="A"*43+"=")
                    return self.plan["destinations"][env]
                if mode=="overwrite":names=[{"name":"APPLE_ID"}]
                elif mode=="appear_after_put" and put_happened:names=[{"name":n} for n in m.NAMES]
                else:names=[]
                return {"total_count":len(names),"secrets":names}
            if "/actions/secrets" in path:
                return {"secrets":[{"name":n,"updated_at":"changed" if mode=="source" else v} for n,v in self.plan["source_updated_at"].items()]}
            raise AssertionError("unexpected dummy API call")
        return api

    def run_import(self, mode=None, apply=False, calls=None):
        calls=[] if calls is None else calls
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name in m.REVIEWED_FILES:
                f=root/name;f.parent.mkdir(parents=True,exist_ok=True)
                f.write_bytes((ROOT/name).read_bytes() if name!=".github/secret-migration.json" else json.dumps(self.plan).encode())
            with patch.object(m,"api",self.fake_api(calls,mode)), patch("builtins.print"):
                m.import_ciphertext(root,42,self.sha,apply)
        return calls

    def test_import_dry_run_no_mutation(self):
        self.assertFalse(any(payload is not None for _,payload in self.run_import()))

    def test_import_key_overwrite_source_guards(self):
        for mode in ("key","overwrite","source","reviewed"):
            calls=[]
            with self.subTest(mode=mode):
                with self.assertRaises(m.Refusal):self.run_import(mode,apply=True,calls=calls)
                self.assertFalse(any(p is not None for _,p in calls),mode)

    def test_import_rechecks_destination_between_puts(self):
        for mode in ("key_after_put","appear_after_put"):
            calls=[]
            with self.subTest(mode=mode):
                with self.assertRaises(m.Refusal):self.run_import(mode,apply=True,calls=calls)
                self.assertEqual(sum(p is not None for _,p in calls),1)

    def test_cli_dummy_environment_exact_bytes_and_failure_redaction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/"scripts").mkdir();(root/".github").mkdir()
            (root/"scripts/secret-migration.py").write_bytes((ROOT/"scripts/secret-migration.py").read_bytes())
            (root/".github/secret-migration.json").write_text(json.dumps(self.plan))
            env={"PATH":os.environ.get("PATH",""),"GITHUB_REPOSITORY":m.REPO,"GITHUB_EVENT_NAME":"workflow_dispatch",
                 "GITHUB_REF":"refs/heads/main","GITHUB_SHA":self.sha,"GITHUB_RUN_ID":"42","GITHUB_RUN_ATTEMPT":"1"}
            env.update({"SOURCE_"+k:v.decode() for k,v in self.values.items()})
            output=root/"ciphertext/manifest.json"
            import sys
            command=[sys.executable,"-I",str(root/"scripts/secret-migration.py"),"seal","--output",str(output)]
            result=subprocess.run(command,env=env,capture_output=True)
            self.assertEqual(result.returncode,0)
            for entry in json.loads(output.read_text())["entries"]:
                self.assertEqual(SealedBox(self.private[entry["environment"]]).decrypt(m.decoded(entry["encrypted_value"])),self.values[entry["name"]])
            output.unlink();env["SOURCE_APPLE_ID"]=""
            result=subprocess.run(command,env=env,capture_output=True)
            self.assertNotEqual(result.returncode,0);self.assertFalse(output.exists())
            self.assertNotIn(b"DUMMY",result.stdout+result.stderr)
            self.assertIn(b"Migration refused: missing or invalid secret.",result.stderr)

    def test_import_only_nine_ciphertext_environment_puts(self):
        calls=self.run_import(apply=True)
        writes=[(path,payload) for path,payload in calls if payload is not None]
        self.assertEqual(len(writes),9)
        # Literal mapping, independent of m.NAMES, so a shared mapping error cannot pass.
        expected_environments={
            "APPLE_ID":"release-candidate",
            "APP_PROVISION_PROFILE_BASE64":"release-candidate",
            "CERTIFICATE_P12_BASE64":"release-candidate",
            "CERTIFICATE_PASSWORD":"release-candidate",
            "FILEPROVIDER_PROVISION_PROFILE_BASE64":"release-candidate",
            "NOTARIZATION_PASSWORD":"release-candidate",
            "SPARKLE_PRIVATE_ED_KEY":"release-candidate",
            "TEAM_ID":"release-candidate",
            "HOMEBREW_TAP_TOKEN":"production",
        }
        entries={e["name"]:e for e in self.manifest["entries"]}
        expected={
            f"repos/{m.REPO}/environments/{expected_environments[name]}/secrets/{name}":
            {"key_id":entries[name]["key_id"],"encrypted_value":entries[name]["encrypted_value"]}
            for name in expected_environments
        }
        self.assertEqual(dict(writes),expected)
        for _,payload in writes:
            self.assertNotIn("DUMMY",json.dumps(payload))


if __name__=="__main__":unittest.main()
