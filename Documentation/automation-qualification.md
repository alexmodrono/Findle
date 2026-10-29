# Qualifying security, coverage and stress checks

The workflows are prepared for CI, but a local Xcode 27.1 test run does not
qualify the Xcode 26.6 security or coverage baseline. Both baseline files start
as `unqualified`. Security fails closed in this state; coverage publishes its
measurements and explicitly says that its ratchet is not yet active. Do not
require a newly introduced check remotely until its exact revision has run.

## Security analysis

`CodeQL` scans pull requests, main, Tuesday mornings and manual dispatches.
The `CodeQL required` aggregate requires the Swift and Actions matrix jobs to
succeed; cancellation, skipped analysis and unqualified baselines fail it.
Only those jobs have `security-events: write`; checkout credentials are not
persisted, and no release secrets are used.

Swift is extracted from fresh unsigned builds of `Findle` and `FindleMCP`.
There is no compiled or package cache restore in this workflow. A separate
query requires extracted declarations from App, FileProviderExtension,
FindleMCP, SharedDomain, Networking, Persistence and SyncEngine. Merely
archiving source files is insufficient. SARIF is uploaded before the baseline
gate, and artifacts retain SARIF, build logs and extracted file counts for
14 days, including failed qualification runs.

PR scans also evaluate the full source tree. The pinned action otherwise enables
diff-informed queries, which report only findings near changed lines and cannot
establish the initial project baseline. `CODEQL_ACTION_DIFF_INFORMED_QUERIES=false`
uses the override verified in the pinned action's
[feature definition](https://github.com/github/codeql-action/blob/9b3254085494b55a0f7c4c2b3d2d52cc712ce370/src/feature-flags.ts#L243-L247),
[override handling](https://github.com/github/codeql-action/blob/9b3254085494b55a0f7c4c2b3d2d52cc712ce370/src/feature-flags.ts#L572-L579)
and [upstream tests](https://github.com/github/codeql-action/blob/9b3254085494b55a0f7c4c2b3d2d52cc712ce370/src/feature-flags.test.ts#L234-L258).
This is a pinned implementation setting, not a public action input: recheck it
when updating the action. The gate independently rejects SARIF containing an
`incrementalMode` property or the `codeql-action/pr-diff-range` extension, so a
changed override cannot silently qualify a partial scan. Confirm their absence
in the actual qualification artifacts; the first run's diff-informed output is
diagnostic evidence only.

CodeQL query packs place their rule metadata in `tool.extensions`, even when
`tool.driver.rules` is empty. The gate resolves each result's component and rule
reference within that component, following
[SARIF 2.1.0](https://docs.oasis-open.org/sarif/sarif/v2.1.0/os/sarif-v2.1.0-os.html).
A clean result still requires successful invocation metadata, a nonempty rule
set and an explicit results array. Missing or conflicting references fail;
identical rule IDs in different components cannot overwrite one another's severity.

The pinned CodeQL action uses its linked CLI 2.27.3; the custom extraction
query pins `codeql/swift-all` 6.8.6 from that bundle's release. Keep these
versions together when updating the action. The supported runner uses Xcode
26.6, rather than the developer machine's Swift 6.4 toolchain. Swift support
currently ends at 6.3; CLI 2.25.3 introduced 6.3 support.

Maintainer qualification procedure:

1. Review the exact candidate workflow, query, gate/build scripts and source,
   including the official action pins and linked analyzer version. Run that
   revision on GitHub. Confirm the seven extraction counts are nonzero and
   inspect SARIF rule metadata and uploaded code scanning results for both
   languages. A zero finding count alone is not proof of extraction.
2. In a disposable branch, introduce a known vulnerable fixture matched by a
   shipped query, confirm its rule appears in uploaded SARIF and that the gate
   rejects it, then remove it and rerun. The Python SARIF fixture tests validate
   our adapter; they do **not** replace this end-to-end analyzer qualification.
3. Review every initial high/critical finding (`security-severity >= 7.0`). Fix
   actionable findings. For an accepted finding, copy its key from the artifact
   `baseline-candidate.json` and add a specific `reason` and ISO date `expires`.
   Do not copy `REVIEW REQUIRED` placeholders. Medium/low results remain visible
   in code scanning but do not block this gate.
4. Set each language's baseline `status` to `reviewed`, with `source_sha` (the
   scanned 40-character commit), `reviewed_at` (ISO date), and its `accepted`
   map. An empty accepted map is valid only after reviewing a complete scan.
   PR gates read the baseline from the PR base commit, so a PR cannot approve
   its own new findings by editing its baseline.
5. Require the aggregate only after the reviewed baseline passes on its exact
   revision. New findings and expired exceptions then fail. Findings without a
   stable CodeQL fingerprint use a conservative path/region/message identity,
   which may reopen moved findings for review instead of overlooking them.

Bootstrap is deliberately separate from ordinary PR comparison. When main has
no reviewed baseline, the first implementation PR remains unqualified even if
its head contains a reviewed file. Its complete scan can nevertheless supply
the initial evidence after a maintainer reviews the exact executed inputs
above. Merely approving a workflow run or downloading an arbitrary PR artifact
does not establish that trust. No placeholder workflow on main is needed.

For this first-PR rollout:

1. Record the repository, PR, run ID and attempt, reviewed head/base SHAs,
   actual checkout SHA, analyzer version and evidence artifact hashes. Use the
   actual checkout SHA for `source_sha`: the current `pull_request` checkout
   scans GitHub's synthetic merge commit, which can differ from the head SHA.
   See [GitHub's PR merge behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request).
   Retain the reviewed evidence before the 14-day artifact expiry.
2. Prepare the provisional reviewed baseline from the complete, clean scan.
   Using the reviewed gate script and downloaded SARIF, check that this scan
   passes against that provisional file and the real known-bad fixture scan
   fails with **new high/critical findings** against the same file. An
   unqualified-baseline error alone does not demonstrate fixture rejection.
   Keep these qualification checks separate from the unchanged PR gate; never
   add the fixture finding to accepted exceptions. If the fixture was added
   to the implementation branch, remove it and obtain a fresh complete scan.
   If it lived only in a separate disposable PR, close that PR without merging
   and verify that the reviewed implementation checkout never contained it.
   In either case, the updated implementation PR must pass a fresh full scan
   against the reviewed base before its changes or required check are accepted.
3. Have the maintainer review and merge a separate bootstrap PR containing
   **only `.github/codeql-baseline.json`**, with the evidence and exception
   review linked in its description and Kanvas. It approves that specific
   baseline, not the implementation PR or its other changes. Introduce the
   required aggregate remotely only after qualification succeeds.
4. Update the implementation branch against the new main so a fresh PR event
   uses the reviewed base baseline; preserve that file when reconciling the
   branch. Verify the event's base SHA contains it and both language jobs and
   the aggregate pass. An old run's **Re-run jobs** button keeps its original
   SHA/ref and is not a substitute for this fresh event; see
   [GitHub's rerun semantics](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs).

A maintainer-triggered `workflow_dispatch` on the same reviewed revision is
also valid when available. GitHub's [manual dispatch requirements](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
require that workflow to exist on the default branch; dispatch is optional for
this bootstrap. Neither route permits ordinary PRs to trust their head
baseline or disables the gate to make the first scan appear green.

The repository maintainer owns alert triage and exception expiry. Vulnerabilities
should follow [the existing private reporting policy](../SECURITY.md), without
tokens, credentials or personal course contents in public issues. Existing
secret scanning, push protection and dependency alert settings are not changed
by these workflows.

## Coverage

The Debug CI matrix enables native Xcode coverage and retains the xcresult,
raw `xccov` JSON, source/module summary and exact toolchain string. PR summaries
also list changed critical Swift files and identify files that were not
instrumented. Counts only describe instrumented source: they do not imply all
application code is exercised. When a source file is compiled into several
targets, the summary uses its best covered copy and largest executable-line
denominator, without pretending to merge per-line execution.

After the first complete Debug CI run, inspect the raw report and set
`.github/coverage-baseline.json` to `reviewed`. Preserve the exact `toolchain`
and `configuration`, and populate all seven `modules` with their measured
fractions from `coverage-summary.json`. Do not invent a target percentage.
The comparison fails if any measured module regresses, disappears or changes
toolchain. Raise these measured floors as coverage improves; a deliberate
exception or toolchain change needs a reviewed baseline update. PRs compare
against their base commit's baseline, rather than their own proposed change.

Stress measurements use different configurations/subsets and deliberately do
not compare against the full Debug baseline.

## Scheduled stress

`Stability stress` runs weekly on Wednesday and manually. Separate macOS 26 /
Xcode 26.6 jobs run optimized Nightly, Thread Sanitizer, and Address Sanitizer;
an additional optimized lane runs macOS 15 / Xcode 26.3. The latter covers the
oldest supported OS family on current hosted images, not precisely macOS 15.0.
macOS 27 is currently a preview runner and is not silently substituted for
these stable images. Recheck runner/toolchain availability when upgrading.

To qualify all four lanes before merging the workflow to main, add the
`stability-stress` label to a PR targeting main. Pushing new commits or reopening
the PR while that label remains present starts a fresh run. New PR runs cancel
superseded stress runs for the same PR; scheduled and manual runs retain their
existing behavior without canceling an in-progress run. PRs without the label
skip the stress jobs. This opt-in path uses the same read-only token and
disposable fixtures as scheduled runs, with no secrets.

Each lane repeats Persistence, SyncEngine, FileProvider, FindleMCP and
Networking suites three times, relaunching test processes and stopping on the
first failure. There are no failure retries. Existing fixtures exercise
migrations, concurrent SQLite readers, cancellation, sync recovery, malformed
HTTP and loopback lifecycle. The seeded database test adds 80 bounded
publication/failure/replay/reopen rounds using only a temporary SQLite store.
Its default seed is `20261029`; manual dispatch accepts another unsigned
integer. The seed is forwarded to test processes and included with duration,
exit status, logs and the xcresult in 14-day artifacts. Each job has a 60-minute
ceiling and each test a 180-second ceiling. Scheduled failures use ordinary
GitHub Actions failure status/notifications; no custom messaging token is needed.

To reproduce locally with a generated project and resolved packages:

```sh
FINDLE_STRESS_SEED=20261029 bash scripts/run-stress.sh thread /tmp/findle-thread-check
```

Use a new output directory per run. The script isolates DerivedData, products,
objects, precompiled headers and packages, so machine-specific Xcode output
settings cannot redirect the build. It never installs an app, registers a File
Provider domain or uses a real account. These jobs do not replace signed File
Provider testing, institution SSO qualification or the 48-hour soak.

## Swift dependency proposals

The Monday `Swift dependency proposals` workflow performs read-only discovery
with the existing read-only Actions token and publishes a summary plus JSON
artifact. It inspects at most 200 upstream tags each for Sparkle and MCP,
separates major/pre-1.0 minor changes, and proposes only a forward immutable
Airlock revision from its default branch. If that branch is behind or diverges
from the pinned AppKit revision, it explicitly leaves Airlock unchanged. Failed
discovery is a failed job, not a misleading “no updates” result.

Each candidate includes an exact apply command. On macOS with the pinned
XcodeGen installed, `scripts/update-swift-dependency.py` updates `project.yml`,
generates the real project, resolves Swift packages and verifies the selected
dependency's version/revision in the canonical `Package.resolved`. It uses no
dummy `Package.swift`. Generator/resolver failures restore the original
manifest and lockfile bytes, including preexisting edits; regenerate the
disposable Xcode project after a failure. Review any transitive lockfile changes.

Examples for an explicit candidate (substitute the reviewed version or SHA):

```sh
python3 scripts/update-swift-dependency.py Sparkle 2.10.0 --dry-run
python3 scripts/update-swift-dependency.py MCP 0.12.1 --dry-run
python3 scripts/update-swift-dependency.py Airlock FULL_40_CHARACTER_COMMIT --dry-run
```

Remove `--dry-run` to resolve and update both files. Major and pre-1.0 minor
updates require `--allow-breaking`; semantic-version downgrades are rejected. The tool neither
commits nor opens PRs. Maintain at most one draft PR per dependency (three
total), run CI and CodeQL, and review before merging. The first scheduled
artifact and each real dependency PR still need CI qualification. The
workflow needs no new secret and grants no approval or merge permission.

GitHub Actions updates continue through the grouped Dependabot configuration.
Automatic Swift PR creation is intentionally not claimed: native Dependabot
does not model these XcodeGen constraints, and using a write-enabled token for
upstream package execution would expand the current credential boundary.

## Release build tools

Release staging installs the verified XcodeGen 2.44.1 binary and create-dmg
1.3.0 before importing signing material. The DMG installer uses upstream commit
`a2b71d0fda6d0df2a86dc7f67082d4d73e84c59f`, checks the official archive against
the recorded SHA-256, and verifies the tool's reported version. It retains the
existing Finder window, app icon and Applications link layout. Update version,
commit and checksum together in `scripts/install-release-tools.sh`; no unpinned
Homebrew tool is installed during signing.

Primary references checked October 29, 2026:

- [CodeQL language support](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/)
- [Swift 6.3 support in CodeQL 2.25.3](https://github.blog/changelog/2026-05-08-codeql-2-25-3-adds-swift-6-3-support/)
- [CodeQL manual builds](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/codeql-for-compiled-languages)
- [macOS 26 runner](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)
- [macOS 15 runner](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
- [create-dmg 1.3.0](https://github.com/create-dmg/create-dmg/releases/tag/v1.3.0)
