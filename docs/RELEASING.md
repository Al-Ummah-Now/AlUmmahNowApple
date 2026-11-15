# Releasing the apps

**Rule:** release builds are made, signed and uploaded **only by CI** (`.github/workflows/release.yml`) from a
`vX.Y.Z` tag (optionally `-N` for a rebuild of the same version) on a commit on `main`. Nobody signs, notarizes or
uploads by hand, and nothing is ever submitted for App Review by CI.

```sh
git fetch origin && git tag -a v0.1.0 -m "v0.1.0" origin/main && git push origin v0.1.0
```

## What a release tag does

Nothing fails because a secret or variable is missing: that step builds unsigned (or is skipped) with a `::notice::`
naming what is missing, and the run stays green.

| Job | Does | Needs (else unsigned / skipped, with a notice) |
|---|---|---|
| `build` StudioMac (Release, QA) | Developer ID signed, notarized, stapled `.dmg` + `.zip` → GitHub release | `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (optionally `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`) |
| `build` StudioIOS, ViewerIOS (Release, QA) | archive, automatic cloud-managed signing, upload to App Store Connect → TestFlight (iPhone + iPad) | the four secrets above |
| `build` ViewerTV (Release, QA) | the same for Apple TV → TestFlight (tvOS) | the four secrets above |
| `build` ViewerMac (Release, QA) | Mac App Store build → App Store Connect → TestFlight for Mac | the four secrets above |
| `publish` | GitHub release with the Studio for Mac files and `SHA256SUMS.txt` | nothing (unsigned files are marked `-unsigned`) |
| `listings` | per app in `APPLE_LISTINGS`: screenshots generated in the job + `store/apple/<app>/metadata` → App Store Connect for this version (`fastlane deliver`, no binary, **no review submission**) | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` + repository variable `APPLE_LISTINGS` |

Without the secrets: Mac apps are ad hoc signed (first launch: right-click › Open); iPhone, iPad and TV builds are
unsigned device archives kept as workflow artifacts only. `workflow_dispatch` builds the same matrix from any branch,
never uploads (the API key is blanked for the run) and never creates a release.

## Version and build number

From the tag (`scripts/release-version.sh`, tested by `scripts/test-release-version.sh` in CI):

- `CFBundleShortVersionString` = `X.Y.Z`.
- `CFBundleVersion` = `((X × 100 + Y) × 100 + Z) × 100 + N`: `v1.2.3` → `1020300`, `v1.2.3-2` → `1020302`. Every tag
  gets a new, higher number, as App Store Connect requires. Y, Z and N stay below 100.
- `workflow_dispatch`: version `0.0.<run>`, build `0.<run>.<attempt>`, below every tag's number, so a dev build can never
  take or block a release number (and it is never uploaded).

`release.sh` checks the archived app carries exactly that version and build, and fails otherwise.

## Apps, bundle ids and App Store Connect records

| App | Scheme | Production id | QA id (QA build, QA servers) | Distribution |
|---|---|---|---|---|
| Al Ummah Now (iPhone, iPad) | `ViewerIOS` | `net.alummahnow.viewer` | `net.alummahnow.viewer.qa` | App Store / TestFlight |
| Al Ummah Now TV | `ViewerTV` | `net.alummahnow.viewer.tv` | `net.alummahnow.viewer.tv.qa` | App Store / TestFlight (tvOS) |
| Al Ummah Now for Mac | `ViewerMac` | `net.alummahnow.viewer.mac` | `net.alummahnow.viewer.mac.qa` | Mac App Store / TestFlight for Mac |
| Al Ummah Now Studio (iPhone, iPad) | `StudioIOS` | `net.alummahnow.studio` | `net.alummahnow.studio.qa` | App Store / TestFlight |
| Al Ummah Now Studio for Mac | `StudioMac` | `net.alummahnow.studio.mac` | `net.alummahnow.studio.mac.qa` | Developer ID (GitHub release); listing ready for a later Mac App Store record |
| Al Ummah Now Admin | see below | | | TestFlight internal only |

## Store listing files

fastlane `deliver` layout, en-US and ar-SA with the same files (`scripts/check-store-metadata.py`, CI job `store`,
checks App Store limits, en/ar parity, URLs and the copy tone):

```
store/apple/apps.json                          app → scheme, bundle id, deliver platform
store/apple/<app>/metadata/{en-US,ar-SA}/
  name.txt              ≤ 30        subtitle.txt          ≤ 30
  promotional_text.txt  ≤ 170       keywords.txt          ≤ 100 bytes (UTF-8, comma-separated)
  description.txt       ≤ 4000      release_notes.txt     ≤ 4000 ("What's New"; edit before each release)
  privacy_url.txt  support_url.txt  marketing_url.txt     https, in the listing's language
store/apple/app-privacy.{md,json}              App Privacy answers drawn from the code, with sources
```

`<app>` is `viewer-ios`, `viewer-tv`, `viewer-mac`, `studio-ios`, `studio-mac`. Privacy URL: there is no privacy
policy page on alummahnow.net or the videos site yet, so it points at the public videos page **Privacy & data**
(`/settings/privacy`: consent choices, data export and deletion). Support: the videos Help Center (`/help`).
Marketing: alummahnow.net.

## Screenshots

`UITests/*/StoreScreenshots.swift` drive the real screens on fixture data (`-AUNUseFixtures YES`, never a QA or
production account; `-AUNFixturePlayable YES` plays a bundled 8 KB clip so the watch page shows the player). They run
only from `scripts/screenshots.sh`:

```sh
make screenshots              # all apps → build/screenshots/<app>/<en-US|ar-SA>/<device>-<NN>-<screen>-<theme>.png
make screenshots APP=viewer-ios
```

iPhone 6.9" 1320×2868 (dark + light), iPad 13" 2064×2752, Apple TV 3840×2160, Mac 2880×1800 (the window, scaled and
centred). Status bar 9:41, full battery. Actions → **Store screenshots** → Run workflow gives them as artifacts; the
`listings` job regenerates them before each upload.

## Universal links

The signed QA and Release builds of the viewer (iPhone, iPad, Mac) and Studio (iPhone, iPad, Mac) carry
`com.apple.developer.associated-domains` = `applinks:$(AUN_LINK_HOST)`: `videos.qa.alummahnow.net` for QA builds,
`videos.alummahnow.net` for Release (`Configs/*.xcconfig`). Debug builds (CI tests, simulator, ad hoc Mac) and unsigned
or certificate-only (`DEVELOPER_ID_P12`) Mac builds use entitlements without them, because a restricted entitlement
without a provisioning profile stops the app from launching. The videos site serves
`/.well-known/apple-app-site-association` from **videos admin → Mobile apps** (404 until the Team ID is entered).

The apps parse links with `AppLink` (`Packages/AUNCoreBridge/Sources/AUNCoreBridge/AppLink.swift`, tests in
`AppLinkTests`): viewer `/{en,ar}/video/<id>` and `/shorts/<id>` open the watch page; `/playlist`, `/post` and `/@handle`
open the app on Home (no native screen for them yet); Studio `/studio/<channel>/<section>` and `/app/studio/…` select
that channel (when the account can upload to it) and section (Dashboard, Content, Recently deleted, Analytics).

## App Attest (Studio for iPhone and iPad)

Studio's writes to api-videos carry `X-AUN-Native-Proof` once videos admin turns Apple attestation on
(`NativeAttestationService` in `Attestation.swift`, behind the `NativeProofProviding` protocol): config read once an
hour (`GET /api/apps/attestation/config`); off or `404 attestation_off` → nothing is sent; first use on a device
generates and attests a key (`apple/register`), later uses assert with it (`apple/assert`; `unknown_key` → register
again). The proof is cached per signed-in account until 5 minutes before it expires, and a `403
native_proof_required` gets one fresh proof and one retry. Failures are logged and the request goes on without the
header. Entitlement `com.apple.developer.devicecheck.appattest-environment = production` in the signed QA and Release
builds only (both are distributed through TestFlight). The viewer makes no writes and the Mac and TV apps have no App
Attest, so they never attest.

## Owner checklist (Apple)

Everything is built; these are the only things to paste or click. Each one unlocks its step on the next tag.

### 1. Apple Developer Program (organisation)

Enrol the organisation (needs a D-U-N-S number). Note the **Team ID** (developer.apple.com → Account → Membership
details, 10 characters).

### 2. App Store Connect API key (unlocks signing, TestFlight uploads, notarization, listings)

App Store Connect → Users and Access → Integrations → App Store Connect API → **Team Keys** → Generate API Key, access
**Admin** (it creates App IDs, capabilities, certificates and profiles through `-allowProvisioningUpdates`, uploads
builds and listings). Download the `.p8` (only once). GitHub → this repo → Settings → Secrets and variables → Actions →
**New repository secret**:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | the Team ID from step 1 |
| `ASC_KEY_ID` | the key's Key ID |
| `ASC_ISSUER_ID` | the Issuer ID shown above the keys list |
| `ASC_KEY_P8` | the whole `.p8` file, including the BEGIN/END lines |
| `DEVELOPER_ID_P12` (optional) | `base64 -i developer-id.p12 \| pbcopy`: a **Developer ID Application** certificate exported from Keychain Access, only if cloud-managed Developer ID signing is not available to the key |
| `DEVELOPER_ID_P12_PASSWORD` (optional) | that export's password |

With `DEVELOPER_ID_P12`, Studio for Mac is signed without a provisioning profile, so that build has no universal links.

### 3. Identifiers (developer portal → Certificates, Identifiers & Profiles → Identifiers)

Xcode registers these through the API key on the first signed build. If it cannot (or to check), create each App ID
and tick its capabilities:

| App ID (and the same with `.qa`) | Capabilities |
|---|---|
| `net.alummahnow.viewer` | Associated Domains |
| `net.alummahnow.viewer.tv` | none |
| `net.alummahnow.viewer.mac` | Associated Domains (App Sandbox is in the app) |
| `net.alummahnow.studio` | Associated Domains, **App Attest** |
| `net.alummahnow.studio.mac` | Associated Domains |

### 4. App Store Connect records (cannot be created through the API)

App Store Connect → Apps → **+** → New App, one per row, primary language English (U.S.), SKU of your choice, then add
**Arabic** as a localization:

| Name | Platform | Bundle ID |
|---|---|---|
| Al Ummah Now | iOS | `net.alummahnow.viewer` |
| Al Ummah Now TV | tvOS | `net.alummahnow.viewer.tv` |
| Al Ummah Now for Mac | macOS | `net.alummahnow.viewer.mac` |
| Al Ummah Now Studio | iOS | `net.alummahnow.studio` |
| Al Ummah Now QA, Al Ummah Now TV QA, Al Ummah Now for Mac QA, Al Ummah Now Studio QA | same platforms | the `.qa` ids |

Studio for Mac ships by Developer ID and needs no record (its listing, `store/apple/studio-mac`, is ready if a Mac App
Store record `net.alummahnow.studio.mac` is added later). If App Store Connect says a name is taken, change the record's
name and the matching `store/apple/<app>/metadata/*/name.txt` in a PR.

Per production record, once (CI does not set these):
- **TestFlight**: an internal group with the testers. External testers need Beta App Review of the first build.
- **App Privacy**: enter the answers from [`store/apple/app-privacy.md`](../store/apple/app-privacy.md)
  (viewer: Data Not Collected; Studio: the five linked types, plus Device ID on iOS).
- **App Information**: category (Photo & Video), content rights, age rating questionnaire.
- **App Review Information** (only when submitting, by hand): Studio needs sign-in, so give Apple a dedicated
  reviewer account with creator access, never the owner's.
- **Privacy Policy URL** is uploaded from `privacy_url.txt`; when a privacy policy page is published, put its address
  in both languages' `privacy_url.txt`.

### 5. Turn on listing uploads (optional)

Repository → Settings → Secrets and variables → Actions → **Variables** → `APPLE_LISTINGS` =
`viewer-ios,viewer-tv,viewer-mac,studio-ios` (any subset of the folders in `store/apple`). From the next tag CI uploads
those apps' texts and screenshots to the version being released. Submitting for review stays a button in App Store
Connect.

### 6. videos admin → Mobile apps (unlocks universal links and App Attest)

In videos admin on each environment (QA: `.qa` bundle ids; production and stage: the production ids; the ids are
pre-filled):

| Field | Value |
|---|---|
| Apple → Team ID | the Team ID from step 1 |
| Apple → apps | already listed: viewer `net.alummahnow.viewer`, `net.alummahnow.viewer.mac`; studio `net.alummahnow.studio`, `net.alummahnow.studio.mac` (+ admin) |
| Apple → App Attest | **on**, environment **production** (TestFlight and App Store builds), only after a signed Studio build is in TestFlight |
| Attestation → enforce client ids (optional, later) | Studio iOS OAuth client ids `6f8073c6-754b-4d63-bf80-0546214e0d62` (production) / `45364a42-21f4-4359-a76c-0a1e6615fd7b` (QA), once proofs show up for Studio writes |

The site then serves `https://videos.alummahnow.net/.well-known/apple-app-site-association` (and the QA host). Check
on a device with a TestFlight build: a link in Notes to `https://videos.qa.alummahnow.net/en/video/<id>` opens the QA
app.

### 7. App icon

[The app icon PR](#) adds the icons from the site's lantern logo (the same mark as the Android launcher); it is held
for your review of the screenshots. App Store Connect rejects uploads without icons, so it must be merged before the
first signed upload.

# Releasing Al Ummah Now Admin (staff only)

The Admin app (wiki `AUN-ADMIN-NATIVE`, AD10) is **internal**: TestFlight internal testing only, for iPhone, iPad and
Mac. There is no public download anywhere: no GitHub Release, no workflow artifact, no `.dmg` (this repo is public).
`.github/workflows/admin-release.yml` builds from an `admin-vX.Y.Z` tag on `main`:

```sh
git fetch origin && git tag -a admin-v0.1.0 -m "Admin v0.1.0" origin/main && git push origin admin-v0.1.0
```

| Build | With the secrets | Without |
|---|---|---|
| Admin iPhone + iPad (`AdminIOS`), production and QA | archived, signed (automatic) and uploaded to App Store Connect, internal testing only | unsigned archive, discarded |
| Admin Mac (`AdminMac`), production and QA | archived, signed for the Mac App Store and uploaded to App Store Connect (TestFlight for Mac), internal only | unsigned archive, discarded |

`workflow_dispatch` builds the same matrix and never uploads. TestFlight builds expire after 90 days: release at least
every 60 days.

## What the owner sets up for Admin (once)

- **Secrets** (same as Studio): `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (App Store Connect team
  key, role Admin, so `-allowProvisioningUpdates` can create the App IDs, profiles and capabilities).
- **Bundle ids** (App IDs): `net.alummahnow.admin`, `net.alummahnow.admin.qa` (iOS + iPadOS) and
  `net.alummahnow.admin.mac`, `net.alummahnow.admin.mac.qa` (macOS).
- **Capabilities on each App ID**: Push Notifications and **Time Sensitive Notifications**
  (`com.apple.developer.usernotifications.time-sensitive`). The Mac ones also need App Sandbox with outgoing network.
  Critical Alerts are not used.
- **Provisioning**: App Store distribution profiles for the four ids (created by Xcode through the API key, or by hand
  in the developer portal if the key's role cannot).
- **App Store Connect records**: "Al Ummah Now Admin" and "Al Ummah Now Admin QA" for iOS, and the same two for macOS,
  with an internal testing group of staff (up to 100 App Store Connect users). Never submitted for review or external
  testing.
- **APNs**: one token-based `.p8` key (Key ID + Team ID) for the processor's direct APNs sender, through the secrets
  flow, never in chat. Topics are the four bundle ids above.
- Debug builds (CI, simulator, ad hoc Mac UI tests) carry no push entitlements, so CI needs none of this.
