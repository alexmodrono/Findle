#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/staging-signed-derived-data}"
DESTINATION="${DESTINATION:-platform=macOS}"
DEVELOPMENT_TEAM_ARG=()

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  DEVELOPMENT_TEAM_ARG=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi

echo "==> Building signed Staging app"
echo "    This build is intended for real SSO, File Provider, and Finder validation."

xcodebuild \
  -project "$ROOT_DIR/Foodle.xcodeproj" \
  -scheme "Foodle-Staging" \
  -configuration Staging \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "${DEVELOPMENT_TEAM_ARG[@]}" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Staging/Findle.app"

cat <<EOF

Signed Staging build passed.

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
