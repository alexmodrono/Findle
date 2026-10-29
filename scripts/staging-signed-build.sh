#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/nightly-signed-derived-data}"
DESTINATION="${DESTINATION:-platform=macOS}"
DEVELOPMENT_TEAM_ARG=()
SOURCE_REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD)"
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
  SOURCE_REVISION="$SOURCE_REVISION-dirty"
fi
# fileproviderd retries cannotSynchronize items after an extension update.
# Reusing build 1 for every signed Nightly makes that update ambiguous.
if [[ -z "${FINDLE_BUILD_NUMBER:-}" ]]; then
  if [[ "$SOURCE_REVISION" == *-dirty || "$(git -C "$ROOT_DIR" rev-parse --is-shallow-repository)" == true ]]; then
    echo "Set FINDLE_BUILD_NUMBER for a dirty or shallow checkout; choose a value newer than the installed Nightly." >&2
    exit 1
  fi
  FINDLE_BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD)"
fi
if [[ ! "$FINDLE_BUILD_NUMBER" =~ '^[1-9][0-9]{0,3}$' ]]; then
  echo "FINDLE_BUILD_NUMBER must be an integer from 1 through 9999." >&2
  exit 1
fi

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  DEVELOPMENT_TEAM_ARG=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi

xcodegen generate --spec "$ROOT_DIR/project.yml"

echo "==> Building signed Nightly app"
echo "    This build is intended for real SSO, File Provider, and Finder validation."

xcodebuild \
  -project "$ROOT_DIR/Findle.xcodeproj" \
  -scheme "Findle-Nightly" \
  -configuration Nightly \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  FINDLE_SOURCE_REVISION="$SOURCE_REVISION" \
  CURRENT_PROJECT_VERSION="$FINDLE_BUILD_NUMBER" \
  OBJROOT="$DERIVED_DATA_PATH/Build/Intermediates.noindex" \
  SYMROOT="$DERIVED_DATA_PATH/Build/Products" \
  SHARED_PRECOMPS_DIR="$DERIVED_DATA_PATH/Build/Intermediates.noindex/PrecompiledHeaders" \
  "${DEVELOPMENT_TEAM_ARG[@]}" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Nightly/Findle Nightly.app"

cat <<EOF

Signed Nightly build passed.
Source: $SOURCE_REVISION
Build: $FINDLE_BUILD_NUMBER

Built app:
  $APP_PATH

Use this app bundle for end-to-end validation:
  1. Complete onboarding and browser SSO.
  2. Verify Finder/File Provider registration succeeds.
  3. Restart the app and confirm the session is restored.
  4. Materialize at least one Finder file and verify download succeeds.

If this command fails, verify Automatic Signing is configured in Xcode for the app and File Provider targets.
You can also pass your team from the shell, for example:
  DEVELOPMENT_TEAM=ABCDE12345 ./scripts/staging-signed-build.sh
EOF
