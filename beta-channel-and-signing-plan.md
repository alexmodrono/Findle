# Findle — Local Signing + Signed Beta Channel

**Status:** Part 1 done · Parts 2–4 for review · **Date:** 2026-05-30

Goal: (1) stop re-adding the dev team after every `xcodegen generate` without committing it, and (2) ship a **signed, notarized beta** that coexists with production so features can be tested end-to-end (File Provider included) before a stable release.

Decisions locked: **signed + notarized** beta · triggered by **prerelease tags** (`v*-beta.*`).

---

## What already exists (good foundation)

- A **`Nightly` config + `Foodle-Nightly` scheme** with isolated bundle IDs (`es.amodrono.foodle.nightly[.file-provider]`) and app group (`group.es.amodrono.foodle.nightly`).
- **`BundleIdentifiers.swift`** derives app group, keychain service, File Provider domain ID, Spotlight prefix, and action IDs from `Bundle.main.bundleIdentifier` at runtime — so those are **already variant-isolated**. The hardcoded `es.amodrono.foodle` strings elsewhere are only Logger subsystems (cosmetic).
- **Entitlements** use `$(APP_GROUP_IDENTIFIER)` / `$(FOODLE_BUNDLE_PREFIX)` / `$(PRODUCT_BUNDLE_IDENTIFIER)`, so app group, keychain group, and Sparkle XPC names vary per variant automatically.
- A **production `release.yml`** (tag `v*`): import cert → install profiles → archive → export developer-id → notarize → DMG/ZIP → Sparkle-sign → appcast → GitHub Release → Homebrew cask.
- A **`pr-nightly.yml`** that builds the Nightly scheme **unsigned** on PRs.

So the variant scaffolding is mostly there. Four gaps remain.

---

## The four gaps

| # | Gap | Status |
|---|-----|--------|
| 1 | No committed `DEVELOPMENT_TEAM` → re-set in Xcode every regen | **✅ Done (Part 1)** |
| 2 | `SUFeedURL` hardcoded to the **production** appcast → a Nightly build checks the prod feed and offers to "update" to prod | Part 2 |
| 3 | File Provider domain **display name** is the Moodle site name in both variants → prod & beta look identical in Finder's sidebar | Part 2 |
| 4 | Nightly CI build is **unsigned** → File Provider can't load, Gatekeeper blocks → not actually testable | Part 3 |

---

## Part 1 — Local signing without committing the team ✅ DONE

A gitignored `Config/Signing.local.xcconfig` holds `DEVELOPMENT_TEAM`, `#include?`-d by the Debug / Nightly / Release xcconfigs for the app and the extension. It survives `xcodegen generate`, never touches git, and CI overrides signing from secrets so it's local-only.

**Implemented:**
- `Config/Signing.local.xcconfig` (gitignored) + `Config/Signing.local.xcconfig.example` (committed)
- `Config/Debug-App.xcconfig`, `Config/Debug-FileProvider.xcconfig` (new) + `#include?` added to Nightly/Release app+FP xcconfigs
- `project.yml`: Debug `configFiles` for `Foodle` and `FoodleFileProvider`
- `.gitignore`: `Config/Signing.local.xcconfig`

**Your one action:** paste your Team ID into `Config/Signing.local.xcconfig`:
```
DEVELOPMENT_TEAM = A1B2C3D4E5
```
Verified: regenerates clean, file is git-ignored, Debug build succeeds.

---

## Part 2 — Coexistence fixes (code)

These make a beta install behave like a genuinely separate app. Both are low-risk and prod is unaffected (the beta-only branches key off the bundle ID).

### 2a. Per-variant Sparkle feed (gap 2)
Parameterize the feed URL by build setting instead of hardcoding it.

- `Resources/Info/App-Info.plist`: `SUFeedURL` → `$(SU_FEED_URL)`
- `project.yml` `settings`:
  - `base.SU_FEED_URL` = production appcast (`…/releases/latest/download/appcast.xml`)
  - `configs.Nightly.SU_FEED_URL` = **beta** appcast (see §Beta appcast hosting)

Result: prod checks the prod feed, beta checks the beta feed — no cross-channel "updates". (The shared `SUPublicEDKey` can stay; the same EdDSA key signs both channels — separation is by feed URL + bundle ID.)

### 2b. Distinguish the File Provider domain in Finder (gap 3)
Add a variant flag and tag the domain display name for non-release builds.

- `BundleIdentifiers.swift`: add `isNightly` (`prefix.hasSuffix(".nightly")`) and a helper, e.g. `fileProviderDomainDisplayName(_ base: String) -> String` that returns `"\(base) (Beta)"` when `isNightly`, else `base`.
- `AppState.swift`: route the ~8 `NSFileProviderDomain(identifier:displayName:)` call sites through that helper so the beta shows e.g. **"My University (Beta)"** in Finder while prod stays **"My University"**.

### 2c. (Optional) distinct beta app icon
A tinted/badged `AppIcon` variant for Nightly (asset catalog + `ASSETCATALOG_COMPILER_APPICON_NAME` override) so the Dock/Finder icon is visually distinct. Cosmetic; can defer.

---

## Part 3 — Signed beta CI (`/.github/workflows/beta.yml`)

A new workflow mirroring `release.yml`, triggered on **`v*-beta.*`** tags, building the **Nightly** variant and publishing a **prerelease**.

Key differences from `release.yml`:
- `on: push: tags: ['v*-beta.*']`
- `SCHEME: Foodle-Nightly`, `-configuration Nightly`, `APP_NAME: "Findle Beta"`, `BUNDLE_ID: es.amodrono.foodle.nightly`
- Install **nightly** provisioning profiles (new secrets) and write the **`Nightly-App` / `Nightly-FileProvider`** signing xcconfigs (manual, `Developer ID Application`, nightly profile UUIDs).
- `ExportOptions.plist` `provisioningProfiles` maps `es.amodrono.foodle.nightly` and `es.amodrono.foodle.nightly.file-provider`.
- Notarize → DMG/ZIP named `Findle Beta` → Sparkle-sign → generate **beta** appcast.
- `gh release create … --prerelease` (versioned, marked prerelease).
- **Skip the Homebrew cask update** (don't disturb the stable cask). Optional: a separate `findle-beta` cask later.

The prod `release.yml` is unchanged. (Optional later: tighten its tag filter to non-beta tags so `v*-beta.*` can't accidentally match `v*`.)

### Reused secrets
`CERTIFICATE_P12_BASE64`, `CERTIFICATE_PASSWORD`, `TEAM_ID`, `APPLE_ID`, `NOTARIZATION_PASSWORD`, `SPARKLE_PRIVATE_ED_KEY` — all shared with prod.

### New secrets
- `NIGHTLY_APP_PROVISION_PROFILE_BASE64`
- `NIGHTLY_FILEPROVIDER_PROVISION_PROFILE_BASE64`

---

## Part 4 — One-time Apple-portal setup (manual — only you can do this)

This is the price of a signed beta where the File Provider works. In the [Apple Developer portal](https://developer.apple.com/account):

1. **Register App IDs**
   - `es.amodrono.foodle.nightly` — enable **App Groups** capability
   - `es.amodrono.foodle.nightly.file-provider` — enable **App Groups**
2. **Register App Group** `group.es.amodrono.foodle.nightly`, and associate both App IDs with it.
3. **Create Developer ID provisioning profiles** for both nightly App IDs (Developer ID distribution, including the app group entitlement).
4. **Export + add GitHub secrets** (base64 the `.provisionprofile` files):
   ```bash
   base64 -i nightly-app.provisionprofile | pbcopy           # → NIGHTLY_APP_PROVISION_PROFILE_BASE64
   base64 -i nightly-fileprovider.provisionprofile | pbcopy  # → NIGHTLY_FILEPROVIDER_PROVISION_PROFILE_BASE64
   ```

(No new certificate or notarization account needed — the existing Developer ID cert + notarytool creds cover the beta.)

---

## Beta appcast hosting

Prereleases aren't "latest", so the prod trick (`releases/latest/download/appcast.xml`) won't serve betas. **Recommended:** a rolling appcast asset on a fixed, prerelease GitHub release.

- Maintain one release with a stable tag, e.g. **`beta-channel`** (marked prerelease).
- Each beta build **overwrites** its `appcast.xml` asset (append/replace the `<item>`).
- Nightly `SU_FEED_URL` = `https://github.com/alexmodrono/Findle/releases/download/beta-channel/appcast.xml` — a stable URL.

Alternative: publish the beta appcast to a `gh-pages` branch (`…github.io/Findle/appcast-beta.xml`). Slightly more setup; also fine.

---

## Suggested order

1. **Part 2a/2b** (coexistence code) — small, prod-safe, makes any beta behave correctly.
2. **Part 4** (you, Apple portal) — unblocks signing; can happen in parallel.
3. **Part 3** (`beta.yml`) — lands once the nightly profiles/secrets exist.
4. Tag `v0.2.0-beta.1`, install alongside prod, verify File Provider + isolation.

---

## Decisions log

| # | Decision | Rationale |
|---|----------|-----------|
| B1 | Local team via gitignored `#include?` xcconfig | Survives regen; team ID never committed; CI overrides from secrets |
| B2 | Signed + notarized beta (not unsigned) | File Provider extension can't load unsigned; Gatekeeper blocks — unsigned can't test the core feature |
| B3 | Trigger on `v*-beta.*` prerelease tags | Explicit, versioned, reuses release.yml machinery |
| B4 | Separate beta appcast + per-variant `SUFeedURL` | Prevents beta→prod cross-channel updates |
| B5 | Beta domain shows "(Beta)" in Finder | Domain IDs already differ; only the display label collided |
| B6 | Beta skips the Homebrew cask | Keep the stable cask clean; beta is opt-in download/auto-update |

## Open questions

1. **Beta appcast hosting:** rolling asset on a fixed `beta-channel` prerelease (recommended) vs `gh-pages`?
2. **Beta version scheme:** `CFBundleShortVersionString` from the tag (`0.2.0-beta.1`) and `CFBundleVersion` from the CI run number — OK?
3. **Distinct beta icon (2c):** want it now, or defer?
4. **Prod tag filter:** also tighten `release.yml` to exclude `-beta` tags now, to be safe?
5. **Alpha tier too?** A third even-rougher channel, or is beta enough?

---

*Comment inline and I'll revise. Part 1 is already in the working tree (uncommitted); I'll implement Parts 2–3 once you've reviewed, and you can run Part 4 in parallel.*
