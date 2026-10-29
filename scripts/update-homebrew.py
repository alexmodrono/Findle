#!/usr/bin/env python3
"""Update the cask after promotion, preserving unrelated maintainer changes."""
import base64
import json
import re
import subprocess
import sys


def update_cask(current, version, sha):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Invalid cask version')
    if not re.fullmatch(r'[0-9a-f]{64}', sha):
        raise ValueError('Invalid cask checksum')
    expected_url = '  url "https://github.com/alexmodrono/Findle/releases/download/v#{version}/Findle-#{version}.zip"'
    if not current.startswith('cask "findle" do\n') or expected_url not in current.splitlines():
        raise ValueError('Unexpected cask identity or download URL; review before updating')
    versions = re.findall(r'^  version "([0-9]+\.[0-9]+\.[0-9]+)"$', current, flags=re.MULTILINE)
    checksums = re.findall(r'^  sha256 "([0-9a-f]{64})"$', current, flags=re.MULTILINE)
    if len(versions) != 1 or len(checksums) != 1:
        raise ValueError('Expected one stable cask version and checksum; review before updating')
    previous = tuple(int(component) for component in versions[0].split('.'))
    proposed = tuple(int(component) for component in version.split('.'))
    if proposed < previous:
        raise ValueError('Refusing to downgrade Homebrew after a newer release was promoted')
    if proposed == previous and sha != checksums[0]:
        raise ValueError('The same immutable release version cannot have a different checksum')
    for pattern, replacement in [
        (r'^  version "[^"\n]+"$', f'  version "{version}"'),
        (r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{sha}"'),
        (r'^  depends_on macos: ">= :(?:sonoma|sequoia)"$', '  depends_on macos: ">= :sequoia"'),
    ]:
        current, count = re.subn(pattern, replacement, current, flags=re.MULTILINE)
        if count != 1:
            raise ValueError('Unexpected cask structure; review before updating')
    return current


def main():
    with open(sys.argv[1]) as stream:
        manifest = json.load(stream)
    version = manifest['version']
    sha = manifest['assets'][f'Findle-{version}.zip']['sha256']
    endpoint = 'repos/alexmodrono/homebrew-tap/contents/Casks/findle.rb'
    response = subprocess.run(['gh', 'api', endpoint], check=True, text=True, capture_output=True)
    current = json.loads(response.stdout)
    previous = base64.b64decode(current['content']).decode()
    text = update_cask(previous, version, sha)
    if previous == text:
        print('Homebrew already matches the published candidate')
        return
    payload = {'message': f'Update findle to {version}', 'sha': current['sha'],
               'content': base64.b64encode(text.encode()).decode()}
    # A concurrent edit produces a conflict; never overwrite it blindly.
    subprocess.run(['gh', 'api', '--method', 'PUT', endpoint, '--input', '-'],
                   input=json.dumps(payload), text=True, check=True, stdout=subprocess.DEVNULL)
    print('Homebrew now matches the published candidate')


if __name__ == '__main__':
    main()
