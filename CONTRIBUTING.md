# Contributing

Use a pull request against `main` and link the relevant Kanvas task. Describe the
behavior change and meaningful validation. Follow [AGENTS.md](AGENTS.md), including
the shared board and interface review guidance.

Generate the Xcode project from `project.yml`; retain its canonical
`Findle.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Do not commit a local Airlock path, signing configuration, provisioning profile,
credential or generated build product. The supported CI toolchain and local test
commands are in [README.md](README.md).

All eight main suites, including onboarding, run in Debug and optimized Nightly.
Onboarding also runs in its isolated preview project. `CI required` and `CodeQL required` are stable aggregate
checks, including documentation-only changes. Fork and dependency-bot builds use
read-only tokens and no signing secrets. Formatting and CodeRabbit begin as
advisory checks; a skipped bot review is not a correctness result.

Changes to persistence, authentication, File Provider, personal-file recovery and
release workflows need regression evidence for their failure paths. Prefer
controlled suspension and disposable stores. Preserve existing user files and
uncommitted changes. Signed integration and upgrade/soak evidence are separate
from unsigned unit tests.

The sole maintainer owns final review. A CODEOWNERS self-approval requirement would
make the maintainer's own PRs impossible, so it is not enabled. A ruleset protects
`main`: changes need a pull request, an up-to-date branch with passing `CI required`
and `CodeQL required`, and resolved conversations. Force pushes and branch deletion
are blocked. Repository administrators have a pull-request-only emergency bypass;
record the reason and the omitted checks in the PR and restore normal checks
before release. Do not use it for ordinary red builds.

Release staging and promotion follow [the qualification procedure](Documentation/release-qualification.md).
No merge or successful bot status by itself authorizes a public release.
