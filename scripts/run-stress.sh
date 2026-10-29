#!/bin/bash
set -euo pipefail

# All suites use temporary databases/files, stub HTTP or loopback servers. No
# installed app, File Provider registration, saved account or SSO is exercised.
mode="${1:?usage: run-stress.sh nightly|thread|address OUTPUT_DIRECTORY}"
output="${2:?output directory required}"
mkdir -p "$output"
configuration=Debug
scheme=Findle
# Bash 3.2 with nounset cannot safely expand an empty array. Keep explicit
# flags in every mode, which also prevents inherited sanitizer settings.
sanitizer=(-enableThreadSanitizer NO -enableAddressSanitizer NO)
case "$mode" in
  nightly) configuration=Nightly; scheme=Findle-Nightly ;;
  thread) sanitizer=(-enableThreadSanitizer YES -enableAddressSanitizer NO) ;;
  address) sanitizer=(-enableThreadSanitizer NO -enableAddressSanitizer YES) ;;
  *) echo "Unknown stress mode: $mode" >&2; exit 2 ;;
esac
export FINDLE_STRESS_SEED="${FINDLE_STRESS_SEED:-20261029}"
# Xcode launches test processes with TEST_RUNNER_ variables stripped of prefix.
export TEST_RUNNER_FINDLE_STRESS_SEED="$FINDLE_STRESS_SEED"
export TEST_RUNNER_ASAN_OPTIONS=halt_on_error=1:abort_on_error=1
export TEST_RUNNER_TSAN_OPTIONS=halt_on_error=1
started=$(date +%s)
finish() {
  result=$?
  duration=$(( $(date +%s) - started ))
  printf 'mode=%s\nseed=%s\nmax_iterations=3\nduration_seconds=%s\nexit_status=%s\nsource_revision=%s\n' \
    "$mode" "$FINDLE_STRESS_SEED" "$duration" "$result" "${GITHUB_SHA:-unknown}" > "$output/run.txt"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Stress: %s\n\nSeed `%s`; at most 3 iterations; %ss; exit %s. No failure retries.\n' \
      "$mode" "$FINDLE_STRESS_SEED" "$duration" "$result" >> "$GITHUB_STEP_SUMMARY"
  fi
}
trap finish EXIT
xcodebuild test -project Findle.xcodeproj -scheme "$scheme" \
  -configuration "$configuration" -destination 'platform=macOS' \
  -derivedDataPath "$output/DerivedData" \
  -clonedSourcePackagesDirPath "$output/SourcePackages" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:PersistenceTests -only-testing:SyncEngineTests \
  -only-testing:FileProviderTests -only-testing:FindleMCPTests \
  -only-testing:NetworkingTests \
  -test-iterations 3 -run-tests-until-failure -test-repetition-relaunch-enabled YES \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 180 \
  -enableCodeCoverage YES "${sanitizer[@]}" \
  -resultBundlePath "$output/results.xcresult" \
  OBJROOT="$output/Objects" SYMROOT="$output/Products" \
  SHARED_PRECOMPS_DIR="$output/Precomps" \
  FINDLE_SOURCE_REVISION="${GITHUB_SHA:-unknown}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$output/build.log"
