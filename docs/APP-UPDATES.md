# App updates on Apple platforms (APPUPD-10): plan

Spec: wiki `epics/AUN-APP-UPDATES-app-updates.md` §4.1.1, §7, §9, §12. A1 is built (no caller yet); the rest is planned.

## What each app does

| App | Source | Update does |
|---|---|---|
| Viewer (iPhone, iPad, Apple TV, Mac), Studio (iPhone, iPad) | `appstore`, `testflight` | Opens its store. Never downloads code |
| Admin (iPhone, iPad, Mac) | `testflight` | Opens TestFlight |
| Studio for Mac | `direct` | Sparkle 2, after our own manifest check; otherwise the notice with the fixed link |

## Pull requests, in order

1. **A1, the check.** `AUNCoreBridge`: `UpdateChecking`, the answer, the states and the install source
   (`AppTransaction`). Store builds decide in plain Swift, without linking aun-core into the viewer apps; the version
   rules run the shared cases in AlUmmahNowCore `spec/app-updates/versions.json`. `AUNCoreKit`: aun-core `0.4.0-rc.7`
   and the `UpdateChecker` adapter for Studio for Mac, with the Apple root key and key list compiled in.
   Off unless the server's `enabled` is true.
2. **A2, the notice.** Bar, forced screen and (Studio for Mac) Settings → Updates: en + ar, ٠–٩, light and dark, RTL; a
   focusable row on Apple TV. Screenshots for the audit.
3. **A3, Sparkle in Studio for Mac only.** Sparkle pinned to an exact version (2.10.1) in `project.yml`, as a dependency of
   the `StudioMac` target alone (never `AUNCoreKit` or `AUNStudio`, which other apps link); a CI check fails if any Mac App Store or iOS product links it (review guideline 2.4.5(vii)).
4. **A4, release.**
   - `release.yml`: the Sparkle zips, the appcasts, `app-release.json`, and a `sign` job like AlUmmahNowTools' (environment
     `update-signing`, refuses a commit that isn't on `main`, runs nothing else). Sparkle's `edSignature` is plain ed25519
     over the zip's bytes, so `sign` makes it with the same Node script that signs the manifest, straight from
     `UPDATE_SIGNING_KEY` (PKCS#8). If Sparkle's own `sign_update` is ever used instead, it wants the raw 32-byte seed in
     base64, taken from the PKCS#8 value inside that job.
   - Two feeds, never mixed: `appcast-studio-mac.xml` for Release, `appcast-studio-mac-qa.xml` for QA. The QA app has its own
     bundle id and `SUFeedURL`, and its own file in the manifest; each build takes only the item its feed and the manifest
     both name.
   - `scripts/release.sh` signs Sparkle's nested code from the inside out (installer service, `Autoupdate`,
     `Updater.app`, the framework, then the app), in the ad hoc, certificate-only and cloud-signed paths.
   - `admin-release.yml`: `app-release.json`, its signature, the key list and `index.json` to the private release bucket
     (K10 write access). Without K10 the step says so and the release goes on.
   - A test that updates N to N+1 on the runner, with the refusal cases.

## Studio for Mac: how Sparkle is held to our rules

- Our service checks first: key list, signed manifest, channel, no downgrade, yanked. Only then is Sparkle asked.
- `SPUUpdaterDelegate` refuses any item whose version, URL and length aren't the verified manifest's `sparkle-zip`; it
  checks again at install time, so a key revoked or a version yanked in between stops it.
- Sparkle's own checks stay on: `SUPublicEDKey`, `SUVerifyUpdateBeforeExtraction`, HTTPS. Automatic checks off: one
  schedule, ours.
- A custom `SPUUserDriver` draws our bar. Never a Sparkle window, never a restart while uploads or encodes run.
- The app is sandboxed, so Sparkle needs its installer XPC service (`SUEnableInstallerLauncherService`) and the two
  mach-lookup exceptions its documentation lists, in **both** `StudioMac.entitlements` and `StudioMac.debug.entitlements`:
  `release.sh` uses the debug file for unsigned and certificate-only builds. They aren't restricted entitlements. The downloader service isn't needed: the app has network access.
  Signed inside out, without `--deep` (Sparkle's own warning).
- `SUPublicEDKey` is the Apple release key (K3). A build accepts only updates that key signed, and it can't be changed in
  place without a Developer ID. If K3 is replaced but not revoked, releases stay signed by both keys. If K3 is **revoked**,
  installed builds trust the new key for the manifest but Sparkle refuses the zip it signs: those builds show the notice
  with the fixed link, and a person downloads the next version once. Our service decides that before asking Sparkle (the
  manifest's key isn't `SUPublicEDKey`), so nobody sees a failed update.

## Open until tested on a real Mac

- Sparkle with an ad hoc signature **and** the sandbox: its sources accept ad hoc, but the installer service and App
  Management on a normal user's Mac aren't proven by a runner. If either fails, Studio for Mac ships the notice with the
  fixed link and Sparkle waits for K6.
- `scripts/release.sh` builds unsigned Studio with the Debug entitlements. A1 to A3 must not add a restricted entitlement.

## Conflicts

#97, #98 and #99 change `Localizable.strings`, `StudioBootstrap`, `Services`, `SharedViews`, `ViewerRootIOS/Mac` and
`TVViews`. A1 adds new files only (plus one line in `StudioBootstrap` and `Package.swift`). A2 starts after those three
merge. #34 to #43 also touch Studio; A2 and A3 rebase on whichever is in.
