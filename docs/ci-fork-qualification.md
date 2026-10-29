# Temporary fork CI qualification

This documentation-only branch exercises Findle pull-request workflows from an actual fork of the repository. It must not be merged.

Baseline: `5a2e7515e3cf70829cfdf393615092e5b5570c78`.

The first revision must produce passing required CI/security checks and an unsigned Nightly artifact with a job-summary download link using read-only credentials. A later revision deliberately fails one disposable XCTest to verify failure propagation. No signing credentials, Moodle account data, releases, or production configuration are involved.

After recording evidence, close this pull request without merging and remove its temporary branch.
