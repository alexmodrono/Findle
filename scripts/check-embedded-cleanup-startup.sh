#!/bin/zsh
set -euo pipefail
# Pass the products directory of a built Findle scheme (contains SharedDomain.framework).
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCTS_DIR="${1:?Usage: check-embedded-cleanup-startup.sh /path/to/Build/Products/Debug}"
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/findle-cold-cleanup.XXXXXX")"
trap 'rm -rf "$PROBE_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  -F "$PRODUCTS_DIR" -framework SharedDomain \
  -Xlinker -rpath -Xlinker "$PRODUCTS_DIR" \
  "$ROOT_DIR/Sources/Networking/Auth/EmbeddedWebDataStoreCleanup.swift" \
  "$ROOT_DIR/Tests/StartupProbes/EmbeddedCleanupMain.swift" \
  -o "$PROBE_DIR/probe"
python3 - "$PROBE_DIR/probe" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], check=True, timeout=20)
PYTHON
