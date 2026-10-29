# Initial major-version build qualification

Recorded October 29, 2026 for Findle
`a135adf0deb63ae10a1200cc17ea1cd6ae654144` and remote Airlock
`b0b90268d7610aedf9fc27f40eb3e42ead3d5aad`. These results establish clean build
reproducibility, not release readiness. Subsequent fixes require fresh validation.

A clean clone of the published Findle branch built the universal optimized
Release configuration with Xcode 27.1, Swift 6.4 and verified XcodeGen 2.44.1.
It used the committed package lockfile without a sibling Airlock checkout or
local signing configuration. The app embeds the exact Findle source revision.
All seven owned executables have matching arm64 and x86_64 dSYM UUIDs, and
all fourteen executable slices target macOS 15.0. The release validator's
`validate_symbols` and `binary_uuids` functions checked the actual products.

The raw build log SHA-256 is
`b3a4ef190e867226b8db8aae52e9eb79b556fd03c8a8d6fdc66d60250c467024`.
Detailed local evidence is retained as `release-symbol-validation.json` in
the clean-build output directory. Those products are unsigned. App and
provider development versions are `1.0`, while shared frameworks use
`1.0.0`; the release workflow assigns the candidate version to all source
plists before archiving. These products have not passed signed-candidate
validation or notarization.

The final local source snapshot passed 372 tests each in Debug and optimized
Nightly, with no failures or skipped tests. The source manifest stayed
unchanged throughout both runs. Release-tool and automation suites also
passed. Local toolchain results do not qualify the hosted coverage or
security baseline.

[The first hosted CI run](https://github.com/alexmodrono/Findle/actions/runs/40860343022)
used macOS 26 and Xcode 26.6. Optimized Nightly, the isolated onboarding
preview and repository checks passed. Debug failed in
`DatabaseTests.testConcurrentSchemaOpenersAgreeOnVersionAndReadiness` with
SQLite 3850 during `BEGIN`. The required aggregate correctly failed; DS-04
was reopened for diagnosis. This failure must be resolved before accepting
the regression pipeline or the application changes.

[The separate hosted Nightly build](https://github.com/alexmodrono/Findle/actions/runs/40860342781)
also produced its unsigned artifact successfully. These clean-runner results
prove that dependency resolution and project generation do not rely on the
developer's sibling checkout or signing files.

Signed Finder integration, institutional sign-in, upgrade/recovery tests and
the release soak remain separate Kanvas gates. No installed app, real account
or provider domain was replaced to obtain this build evidence.
