#!/bin/bash
set -euo pipefail

# The checksum is published by the upstream GitHub release. Keep the version,
# archive digest and README toolchain together when upgrading the generator.
version=2.44.1
sha256=a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73
root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/findle-xcodegen-$version"
mkdir -p "$root"
curl --fail --silent --show-error --location \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip" \
  -o "$root/xcodegen.zip"
printf '%s  %s\n' "$sha256" "$root/xcodegen.zip" | shasum -a 256 --check
unzip -q -o "$root/xcodegen.zip" -d "$root"
test -x "$root/xcodegen/bin/xcodegen"
test "$("$root/xcodegen/bin/xcodegen" --version)" = "Version: $version"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$root/xcodegen/bin" >> "$GITHUB_PATH"
else
  printf 'Pinned generator: %s\n' "$root/xcodegen/bin/xcodegen"
fi
