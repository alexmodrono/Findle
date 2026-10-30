# GH-07: one-time ciphertext migration proposal

DRAFT ONLY. Base: `alexmodrono/Findle` main `5a2e7515e3cf70829cfdf393615092e5b5570c78`. No secret values were accessed during preparation. Public-key metadata and secret names/update timestamps were fetched read-only. The two environments have different public keys but the same key ID; checking the ID alone is insufficient.

## Destination and scope

Eight existing secrets go only to `release-candidate`: APPLE_ID, APP_PROVISION_PROFILE_BASE64, CERTIFICATE_P12_BASE64, CERTIFICATE_PASSWORD, FILEPROVIDER_PROVISION_PROFILE_BASE64, NOTARIZATION_PASSWORD, SPARKLE_PRIVATE_ED_KEY, TEAM_ID. HOMEBREW_TAP_TOKEN goes only to `production`. No repository secret is deleted by this tool. No additional administrative token is put in Actions.

The one-time workflow permits only a first-attempt manual dispatch in the original repository on main. It uses the existing production environment approval gate. The release-candidate environment remains restricted to v* tags. Dependency installation and checkout occur before the sealing step receives secrets. All actions are commit-pinned; PyNaCl, cffi and pycparser are version/hash-pinned binary wheels, independently downloaded and SHA256-checked during drafting.

## Review before any execution

1. Review the five execution inputs together: workflow, public-key plan, sealing/import script, requirements and dummy test suite. Verify the plan's destination keys and repository secret update timestamps still match the live API. If either changed, regenerate/review the plan. Confirm both intended destinations are empty and freeze concurrent secret administration for the operation.
2. Run the included dummy-only tests in Tests/SecretMigrationTests using Python 3.12 and the hashed requirements. Required quality CI runs them on Linux, and the manual workflow repeats them before injecting secrets. Tests generate their own keys and values, including spaces, Unicode and CR/LF; they never use the stored destination keys to encrypt real values.
3. Merge the reviewed files through the ordinary main protections. Record the exact resulting main SHA. This is different from the draft's base SHA. Review the complete commit before dispatching the workflow from main and approving its production environment job. No PR event or tag is used for this migration.
4. The approved runner writes only a ciphertext manifest. Plaintext remains in its step environment/process memory; it is never intentionally printed, passed as a command argument, hashed into a public verifier, cached or written to a file. No full secrets-context serialization is used. The ciphertext artifact expires after one day.

## Local import after a successful approved run

Use a clean local copy containing exactly the five files executed at the reviewed main SHA, with the operator's existing authenticated gh CLI. No new token is requested or installed on the runner. Substitute the known successful run ID and reviewed commit below:

```sh
python3 scripts/secret-migration.py import --run-id RUN_ID --expected-sha REVIEWED_MAIN_SHA
```

The default performs no writes. It checks current main, byte-for-byte executed source/configuration, original-repository workflow_dispatch provenance, run attempt 1, exact artifact identity, GitHub artifact SHA256, bounded ZIP contents, exact nine-name mapping, source timestamps, live destination public keys, and absence of destination names. After reviewing this result, the explicit import command is:

```sh
python3 scripts/secret-migration.py import --run-id RUN_ID --expected-sha REVIEWED_MAIN_SHA --apply
```

The importer sends only `{key_id, encrypted_value}` to fixed github.com environment-secret endpoints. It checks the full destination key and absence of the individual name again immediately before every write. It never calls DELETE or changes settings. Partial failure leaves repository originals intact and any successful environment writes intact; a retry refuses those existing entries. Review partial state manually instead of adding an overwrite option or automatically rolling anything back.

## Verification and removal

Environment metadata and HTTP success are only import evidence, not credential validation. Confirm the exact destination name set, then validate production's tap credential through an approved main environment job using nondestructive API checks. Do not publish or update Homebrew merely to test it.

For the eight release-candidate credentials, wait for a separately authorized real candidate on an eligible v* tag. The existing candidate workflow must actually complete certificate/profile validation, signing, notarization and Sparkle signature verification using the environment secrets. Confirm all eight environment records exist before the job, because a missing environment entry can silently fall back to a repository secret. **Do not add a main branch allowance or create a dummy version tag to bypass this restriction.** Do not delete repository originals until eligible candidate validation succeeds, production credential verification succeeds, and unchanged source metadata has been rechecked. If validation is inconclusive, retain originals and keep GH-07 incomplete.

After qualified verification, repository-original removal is a separate explicit operation; this tool deliberately cannot perform it. Remove the one-time workflow and migration source/configuration after qualification, remove the ciphertext artifact early, and retain only safe run IDs, revisions, counts, statuses and artifact integrity evidence. Do not retain plaintext or credential-derived public hashes. If a replacement/new user-supplied value is required, use the private request_secret tool/file channel, never chat, logs or ordinary command arguments.

## Security limits

- This is a reviewed secret-use workflow, not a GitHub-native move. GitHub's API cannot read existing secret values. Plaintext necessarily exists in GitHub's ephemeral runner memory during sealing, so runner, Python, pinned dependencies/actions and reviewed code remain trusted.
- Ciphertext does not establish origin by itself: anyone knowing a public key can encrypt replacement values. The importer therefore checks the successful run, exact executed code, artifact identity and digest. It cannot decrypt or prove credential usability.
- GitHub exposes an upsert API, with no documented atomic create-only condition. The importer refuses observed existing values, but another administrator could race its final check. Freeze concurrent secret administration; do not claim an atomic overwrite guarantee.
- Public-key rotation, source-secret updates, main movement, retries and partial imports intentionally stop the operation. A fresh reviewed plan/run may be needed. Repository secret timestamps are checked before import; no later deletion should rely on stale checks.
- Python/environment memory is not guaranteed to be zeroized. Core dumps are disabled, no self-hosted runner or cache is used, and no plaintext buffer is intentionally persisted. Ciphertext length reveals value length. The artifact is not a private secret store despite containing only ciphertext.
- Production currently allows self-review. This draft uses the existing approval policy and does not strengthen or bypass it. A reviewer should inspect the exact migration SHA before approving.

References: [GitHub secrets API](https://docs.github.com/en/rest/actions/secrets), [libsodium encryption format](https://docs.github.com/en/rest/guides/encrypting-secrets-for-the-rest-api), [secret scope and timing](https://docs.github.com/en/actions/reference/security/secrets), [workflow security](https://docs.github.com/en/actions/reference/security/secure-use).
