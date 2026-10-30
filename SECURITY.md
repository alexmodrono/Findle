# Security reports

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/alexmodrono/Findle/security/advisories/new).
Do not publish tokens, password submissions, SSO callback payloads, personal file
contents or a working exploit in an issue. Redacted operation/error codes and
build information are useful; inspect diagnostic attachments before sharing.

The repository maintainer, @alexmodrono, owns triage. CodeQL findings cover source
and Actions workflows; security checks complement runtime and data-safety tests.
`CodeQL required` blocks merging to `main` when a pull request introduces a new
high or critical finding. The reviewed baseline in `.github/codeql-baseline.json`
accepts no findings. Scans run on pull requests, on pushes to `main` and weekly.
CodeRabbit is advisory and cannot approve a release.

The next major version is under development. Report issues in the latest public
release and current main; no response-time or support-duration commitment is
implied while the project has one maintainer.
