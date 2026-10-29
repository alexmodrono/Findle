#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
preview_root="$repo_root/build/onboarding-preview"
mkdir -p "$preview_root"

# Keep the generated project and build products separate from Nightly builds.
xcodegen generate --spec "$repo_root/onboarding-preview.yml"
xcodebuild build \
  -project "$repo_root/FindleOnboardingPreview.xcodeproj" \
  -scheme Findle-OnboardingPreview \
  -configuration Debug \
  -derivedDataPath "$preview_root/DerivedData" \
  -IDEBuildLocationStyle=Unique \
  SYMROOT="$preview_root/DerivedData/Build/Products" \
  OBJROOT="$preview_root/DerivedData/Build/Intermediates.noindex" \
  CODE_SIGN_IDENTITY="-"

preview_app="$preview_root/DerivedData/Build/Products/Debug/Findle Onboarding Preview.app"
open "$preview_app"
printf 'Opened %s\nUse student / preview to sign in to the sample site.\n' "$preview_app"
