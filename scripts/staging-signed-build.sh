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
  OBJROOT="$DERIVED_DATA_PATH/Build/Intermediates.noindex" \
  SYMROOT="$DERIVED_DATA_PATH/Build/Products" \
  SHARED_PRECOMPS_DIR="$DERIVED_DATA_PATH/Build/Intermediates.noindex/PrecompiledHeaders" \
  "${DEVELOPMENT_TEAM_ARG[@]}" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Nightly/Findle Nightly.app"

cat <<EOF

Signed Nightly build passed.
Source: $SOURCE_REVISION

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
