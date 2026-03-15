# Homebrew Tap Setup

This file documents how to set up the Homebrew tap for distributing Findle.

## 1. Create the tap repository

Create a new GitHub repo named `homebrew-tap` under your account (e.g., `alexmodrono/homebrew-tap`).
This allows users to install via:

```sh
brew tap alexmodrono/tap
brew install --cask findle
```

The repo just needs to exist — the release workflow will populate it automatically.

## 2. GitHub Secrets

Add these secrets to the **Foodle** repository (Settings > Secrets and variables > Actions):

| Secret | Description |
|---|---|
| `CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application `.p12` certificate. Export from Keychain Access, then: `base64 -i certificate.p12 \| pbcopy` |
| `CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` file |
| `TEAM_ID` | Your Apple Developer Team ID (found in developer.apple.com > Membership) |
| `APPLE_ID` | Your Apple ID email (for notarization) |
| `NOTARIZATION_PASSWORD` | App-specific password for notarization. Generate at appleid.apple.com > Sign-In and Security > App-Specific Passwords |
| `HOMEBREW_TAP_TOKEN` | A GitHub Personal Access Token (classic) with `repo` scope, so the workflow can push to the `homebrew-tap` repo |

## 3. Creating a release

Tag a commit and push:

```sh
git tag v1.0.0
git push origin v1.0.0
```

Then create a GitHub Release from the tag (can be a draft — the workflow uploads artifacts to it):

```sh
gh release create v1.0.0 --title "Findle 1.0.0" --generate-notes
```

The workflow will:
1. Build and archive the app
2. Sign it with your Developer ID certificate
3. Notarize and staple it
4. Create a `.dmg` and `.zip`
5. Upload both to the GitHub Release
6. Update the Homebrew cask formula automatically

## 4. Exporting your Developer ID certificate

1. Open **Keychain Access**
2. Find your **Developer ID Application** certificate (under "My Certificates")
3. Right-click > **Export…** > choose `.p12` format
4. Set a strong password (this becomes `CERTIFICATE_PASSWORD`)
5. Base64-encode it: `base64 -i Certificates.p12 | pbcopy`
6. Paste into the `CERTIFICATE_P12_BASE64` secret

> If you don't have a Developer ID Application certificate, create one in
> developer.apple.com > Certificates, Identifiers & Profiles > Certificates > +
> Choose "Developer ID Application".
