# Release qualification

A tag stages a **draft**. It does not publish an update or change Homebrew.
The tag must identify a commit on `main` with successful `CI` and `CodeQL`
workflow runs for that exact revision. A pull request merge preview or an older
successful run cannot substitute for it. If checks are still running, staging
fails closed; rerun it after they pass.

The protected `release-candidate` job builds, signs, notarizes and staples the
app and disk image, checks bundle versions, channel, signing team, entitlements,
minimum macOS and the Sparkle signature, then stages these files together:

- ZIP and DMG installers;
- matching dSYMs (Mach-O UUIDs verified against every shipped Findle executable) in `Findle-symbols.zip`;
- `Package.resolved`, `appcast.xml`, and `candidate.json` with exact artifact
  sizes, SHA-256 hashes, source and Airlock revisions.

Every staged file has a GitHub build-provenance attestation. Staging verifies
those attestations before upload. It never overwrites an existing asset or
restages a published release. An interrupted upload can resume with the same
candidate bytes. A rebuilt candidate that differs must be reviewed separately;
keep the original artifact download rather than silently replacing it.

Run the signed upgrade/recovery rehearsal (RR-03) and the complete 48-hour soak
(RR-04) against these exact bytes. Record at least 100 cycles, offline/online,
sleep/wake, extension restart, materialization, relaunch, signed upgrade,
personal-file manifests/hashes, and CPU/memory observations. No P0/P1 issue or
personal-file loss/corruption may remain. Unit tests, unsigned previews and
compressed simulated time do not establish this evidence.

Commit the maintainer's decision as `release-qualification/vX.Y.Z.json`, with
supporting redacted evidence beneath `release-qualification/`. The JSON fields
are:

```json
{
  "decision": "no-go",
  "source_revision": "FULL_FINDLE_COMMIT",
  "airlock_revision": "FULL_AIRLOCK_COMMIT",
  "candidate_sha256": "SHA256_OF_DOWNLOADED_CANDIDATE_JSON",
  "signed_candidate": false,
  "started_at": "ACTUAL_ISO8601_START_WITH_TIMEZONE",
  "finished_at": "ACTUAL_ISO8601_END_WITH_TIMEZONE",
  "cycles": 0,
  "open_p0_p1": 1,
  "passed_scenarios": [],
  "personal_files_lost": 0,
  "personal_files_corrupted": 0,
  "reviewer": "MAINTAINER",
  "evidence": [{"path": "RELATIVE_REDACTED_EVIDENCE", "sha256": "EVIDENCE_SHA256"}]
}
```

This deliberately invalid example is not a qualification record. Set `go` only
after reviewing the completed evidence. The required scenario identifiers are
`offline-online`, `sleep-wake`, `extension-restart`, `materialization`, `relaunch`,
`signed-upgrade`, `personal-file-hashes`, and `cpu-memory`.

Validate locally with:

```sh
python3 scripts/release-candidate.py verify /path/to/downloaded/candidate \
  --qualification release-qualification/vX.Y.Z.json \
  --evidence-root release-qualification
```

Dispatch **Promote qualified release** from `main` with that tag. The protected
`production` environment requires the maintainer's release decision. Promotion
checks the record, evidence hashes, source tag, trusted CI, attestations, shipped
Sparkle signature and notarization before publishing the existing draft.
Publication initially leaves the current latest release unchanged. GitHub's
release attestation and every final immutable asset must match the qualified
local files and tag before the new release becomes latest. An older-release
retry cannot move latest or Homebrew backward. If GitHub's release attestation
is not available yet, promotion fails closed and can be rerun.
Homebrew changes only after the public release is verified immutable. A retry
verifies the published bytes again and can repair a failed Homebrew update
without replacing release assets.

Repository administrators must enable immutable releases and set repository
variable `RELEASE_IMMUTABILITY_ENABLED=true` after verifying the setting. Both
release environments use an actual maintainer reviewer; self-review is permitted
for a sole maintainer, without pretending that a second reviewer exists.
Protect release tags from updates/deletions and restrict production deployment
to `main`. Environment and ruleset rollout remain tracked in GH-04/GH-07 until
verified on GitHub.

The stability work authorizes preparation and rehearsal. It does not authorize
publishing the next major release.

References: [GitHub artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations),
[immutable releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases),
[Sparkle publishing](https://sparkle-project.org/documentation/publishing/).
