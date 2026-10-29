#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo 'Usage: sign-update.sh ARCHIVE APP_INFO_PLIST' >&2
  exit 1
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${SIGN_UPDATE:?Set SIGN_UPDATE to the resolved Sparkle signing tool}"
: "${SPARKLE_PRIVATE_ED_KEY:?Missing Sparkle signing key}"
[[ -x "$SIGN_UPDATE" ]] || { echo 'Sparkle signing tool is missing or not executable' >&2; exit 1; }
[[ -s "$1" && -f "$2" ]] || { echo 'Archive or application Info.plist is missing' >&2; exit 1; }

signature="$(printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$SIGN_UPDATE" --ed-key-file - -p "$1")"
swift "$repo_root/scripts/verify-update.swift" "$1" "$signature" "$2"
zip_size="$(stat -f%z "$1")"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'ed_signature=%s\nzip_size=%s\n' "$signature" "$zip_size" >> "$GITHUB_OUTPUT"
fi
