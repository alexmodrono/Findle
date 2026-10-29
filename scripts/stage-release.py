#!/usr/bin/env python3
"""Upload a validated candidate to a draft, without overwriting any asset."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

def digest(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').digest()


root = pathlib.Path(sys.argv[1]).resolve()
manifest = json.loads((root / 'candidate.json').read_text())
revision = manifest['source_revision']
tag = 'v' + manifest['version']
repo = 'alexmodrono/Findle'
files = [root / name for name in [*manifest['assets'], 'candidate.json']]
# Tag identity is checked independently of mutable draft target_commitish.
actual = subprocess.check_output(['git', 'rev-list', '-n', '1', tag], text=True).strip()
if actual != revision:
    raise SystemExit('Release tag differs from candidate revision')
result = subprocess.run(['gh', 'release', 'view', tag, '--repo', repo, '--json', 'isDraft,assets'], capture_output=True, text=True)
if result.returncode:
    # Authentication/network errors are not interpreted as permission to overwrite:
    # create fails safely if the release already exists.
    subprocess.run(['gh', 'release', 'create', tag, '--repo', repo, '--verify-tag', '--draft',
                    '--title', 'Findle ' + manifest['version'], '--notes',
                    f"Candidate for {revision}. Awaiting signed qualification and production promotion.",
                    *map(str, files)], check=True)
else:
    release = json.loads(result.stdout)
    if not release['isDraft']:
        raise SystemExit('Published releases cannot be restaged')
    existing = {asset['name'] for asset in release['assets']}
    if existing - {path.name for path in files}:
        raise SystemExit('Draft contains unexpected assets; review it before continuing')
    with tempfile.TemporaryDirectory() as temp:
        # Validate every existing byte before uploading anything missing.
        for path in files:
            if path.name not in existing:
                continue
            subprocess.run(['gh', 'release', 'download', tag, '--repo', repo, '--pattern', path.name, '--dir', temp], check=True)
            if digest(pathlib.Path(temp) / path.name) != digest(path):
                raise SystemExit('Existing candidate differs; refusing to replace ' + path.name)
        for path in files:
            if path.name not in existing:
                subprocess.run(['gh', 'release', 'upload', tag, str(path), '--repo', repo], check=True)
print('Draft candidate staged; no release was published.')
