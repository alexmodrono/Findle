#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
xcodebuild -version
swift --version

# CI must not depend on a sibling checkout, even if one happens to exist.
ruby -ryaml -rjson -e '
  spec = YAML.load_file("project.yml")
  spec.fetch("packages").each do |name, package|
    abort "::error::Local package dependency is not reproducible: #{name}" if package["path"]
  end
  revision = spec.fetch("packages").fetch("Airlock").fetch("revision")
  abort "::error::Airlock must use an immutable commit" unless revision.match?(/\A[0-9a-f]{40}\z/)
  lock = JSON.parse(File.read("Findle.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
  pin = lock.fetch("pins").find { |pin| pin["identity"] == "airlock" }
  abort "::error::Airlock manifest and lockfile disagree" unless pin && pin.fetch("state")["revision"] == revision
'
