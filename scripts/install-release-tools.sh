#!/bin/bash
set -euo pipefail

# Upstream v1.3.0 resolves to this immutable commit. The SHA-256 was measured
# from its official GitHub archive; keep commit, digest and version together.
version=1.3.0
revision=a2b71d0fda6d0df2a86dc7f67082d4d73e84c59f
sha256=36577b966f16c12dd78d5bb5107c2ae3d069b044226b6ebbffa6a434ce142d0a
root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/findle-create-dmg-$revision"
mkdir -p "$root"
curl --fail --silent --show-error --location \
  "https://github.com/create-dmg/create-dmg/archive/$revision.tar.gz" \
  -o "$root/source.tar.gz"
printf '%s  %s\n' "$sha256" "$root/source.tar.gz" | shasum -a 256 --check
tar -xzf "$root/source.tar.gz" --strip-components 1 -C "$root"
test -x "$root/create-dmg"
test "$("$root/create-dmg" --pure-version)" = "$version"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$root" >> "$GITHUB_PATH"
else
  printf 'Pinned create-dmg: %s\n' "$root/create-dmg"
fi
