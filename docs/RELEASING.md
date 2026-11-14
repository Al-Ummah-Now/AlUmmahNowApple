# Releasing Studio

Releases are built only by GitHub Actions (`.github/workflows/release.yml`), from a `vX.Y.Z` tag on a commit on
`main`. Nobody signs, notarizes or uploads by hand.

```sh
git fetch origin && git tag -a v0.1.0 -m "Studio v0.1.0" origin/main && git push origin v0.1.0
```

| Artifact | Where it goes | Built with secrets | Built without secrets |
|---|---|---|---|
| Studio for Mac, production (`Release`) and QA | GitHub Release: `.dmg`, `.zip`, `SHA256SUMS.txt` | Developer ID signed, hardened runtime, notarized and stapled | ad hoc signed, marked `-unsigned` (first launch: right-click › Open) |
| Studio for iPhone and iPad, production and QA | App Store Connect → TestFlight | archived, signed (automatic, cloud-managed) and uploaded | unsigned device archive, kept as a workflow artifact only |

`workflow_dispatch` builds the same matrix from any branch and keeps the files as workflow artifacts; it never
creates a release. The build number is the workflow run number; the version is the tag.

## Secrets (repository → Settings → Secrets and variables → Actions)

| Secret | What | Used for |
|---|---|---|
| `APPLE_TEAM_ID` | 10-character Team ID of the Apple Developer organisation | automatic signing, export options |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect team API key (role Admin) and the full `.p8` text | `xcodebuild -allowProvisioningUpdates` (certificates, App IDs, profiles), TestFlight upload, `notarytool` |
| `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD` | optional: base64 of a *Developer ID Application* certificate exported as `.p12`, and its password | Mac signing, when cloud-managed Developer ID signing is not available to the API key |

The key file is written to the runner's temp folder and deleted when the job ends; the `.p12` goes into a throwaway
keychain that is deleted too. Nothing is committed.

## App Store Connect setup (once, by an Admin)

- App records: **Al Ummah Now Studio** (`net.alummahnow.studio`, iOS, iPhone + iPad) and, for testers on QA,
  **Al Ummah Now Studio QA** (`net.alummahnow.studio.qa`). App records cannot be created through the API.
- A TestFlight internal group with the testers. External testers need Beta App Review for the first build.
- The Mac app is distributed directly (Developer ID), so it needs no App Store record. TestFlight for Mac would need
  its own record (`net.alummahnow.studio.mac`) and a Mac App Store export; it is not set up.

## Native passkeys (Associated Domains)

"Sign in with a passkey" calls the platform passkey API, which only runs for an app the relying party lists. Each
app claims `webcredentials:$(AUN_PASSKEY_RP_DOMAIN)` (`qa.alummahnow.net` in Debug and QA, `alummahnow.net` in
Release; set in `Configs/*.xcconfig`), and the RP domain serves `/.well-known/apple-app-site-association` with
`<APPLE_TEAM_ID>.<bundle id>` under `webcredentials.apps`.

- The App IDs `net.alummahnow.studio(.qa)` and `net.alummahnow.studio.mac(.qa)` need the **Associated Domains**
  capability. The cloud-managed signing path (`-allowProvisioningUpdates` with the API key) turns it on and makes
  matching profiles by itself.
- The `DEVELOPER_ID_P12` Mac path signs by hand without a profile, so it builds with
  `AUN_MAC_ENTITLEMENTS_VARIANT=.adhoc` (no Associated Domains). That build has no native passkeys; "Sign in another
  way" still works. CI test builds (ad hoc) use the same variant, because macOS will not launch an app that claims a
  restricted entitlement without a profile.

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
