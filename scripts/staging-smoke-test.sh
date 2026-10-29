#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/nightly-derived-data}"
DESTINATION="${DESTINATION:-platform=macOS}"

xcodegen generate --spec "$ROOT_DIR/project.yml"

echo "==> Building Nightly (unsigned optimized validation build)"
xcodebuild \
  -project "$ROOT_DIR/Findle.xcodeproj" \
  -scheme "Findle-Nightly" \
  -configuration Nightly \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  OBJROOT="$DERIVED_DATA_PATH/Build/Intermediates.noindex" \
  SYMROOT="$DERIVED_DATA_PATH/Build/Products" \
  SHARED_PRECOMPS_DIR="$DERIVED_DATA_PATH/Build/Intermediates.noindex/PrecompiledHeaders" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

echo "==> Running Nightly tests"
xcodebuild \
  -project "$ROOT_DIR/Findle.xcodeproj" \
  -scheme "Findle-Nightly" \
  -configuration Nightly \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  OBJROOT="$DERIVED_DATA_PATH/Build/Intermediates.noindex" \
  SYMROOT="$DERIVED_DATA_PATH/Build/Products" \
  SHARED_PRECOMPS_DIR="$DERIVED_DATA_PATH/Build/Intermediates.noindex/PrecompiledHeaders" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Nightly/Findle Nightly.app"

cat <<EOF

Nightly smoke test build/test passed.

Built app:
  $APP_PATH

Important:
  This build is intentionally unsigned so tests can run in a predictable local environment.
  Do not use this app bundle for File Provider, Finder integration, or end-to-end SSO validation.

Manual pre-ship checklist:
  1. Build a signed Nightly app with ./scripts/staging-signed-build.sh or from Xcode.
  2. Launch the signed Nightly app and complete onboarding.
  3. Verify browser SSO completes and lands in the workspace.
  4. If the site uses embedded SSO, verify the sheet loads and the callback returns.
  5. Open the Finder integration and confirm the File Provider root appears.
  6. Restart the app and verify the existing account/session is restored.
  7. Trigger a sync and confirm at least one course enumerates in Finder.
  8. Materialize one file from Finder and verify download completes without crashing.

For signed-distribution confidence, repeat the same checklist with the exported signed artifact.
EOF
