#!/bin/zsh
set -euo pipefail
# Pass the products directory of a built Findle scheme (contains SharedDomain.framework).
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCTS_DIR="${1:?Usage: check-embedded-cleanup-startup.sh /path/to/Build/Products/Debug Debug}"
PROBE_CONFIGURATION="${2:?Pass Debug or Nightly as the second argument}"
typeset -a compiler_flags
case "$PROBE_CONFIGURATION" in
  Debug) compiler_flags=() ;;
  Nightly) compiler_flags=(-whole-module-optimization -Osize) ;;
  *) print -u2 "Unsupported probe configuration: $PROBE_CONFIGURATION"; exit 2 ;;
esac
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/findle-cold-cleanup.XXXXXX")"
trap 'rm -rf "$PROBE_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library "${compiler_flags[@]}" \
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
