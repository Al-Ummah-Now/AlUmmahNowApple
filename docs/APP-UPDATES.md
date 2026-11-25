# App updates on Apple platforms (APPUPD-10): plan

Spec: wiki `epics/AUN-APP-UPDATES-app-updates.md` §4.1.1, §7, §9, §12. Nothing here is built yet.

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
   (now `rc.3`) and the `UpdateChecker` adapter for Studio for Mac, with the Apple root key and key list compiled in.
   Off unless the server's `enabled` is true.
2. **A2, the notice.** Bar, forced screen and (Studio for Mac) Settings → Updates: en + ar, ٠–٩, light and dark, RTL; a
   focusable row on Apple TV. Screenshots for the audit.
3. **A3, Sparkle in Studio for Mac only.** Sparkle pinned to an exact version (2.10.1) as a dependency of that target
   alone; a CI check fails if any Mac App Store or iOS product links it (review guideline 2.4.5(vii)).
4. **A4, release.** `release.yml`: the Sparkle zip, `appcast-studio-mac.xml`, `app-release.json`, and a `sign` job like
   AlUmmahNowTools' (environment `update-signing`, refuses a commit that isn't on `main`). `admin-release.yml`: the private
   manifest. A test that updates N to N+1 on the runner, with the refusal cases.

## Studio for Mac: how Sparkle is held to our rules

- Our service checks first: key list, signed manifest, channel, no downgrade, yanked. Only then is Sparkle asked.
- `SPUUpdaterDelegate` refuses any item whose version, URL and length aren't the verified manifest's `sparkle-zip`; it
  checks again at install time, so a key revoked or a version yanked in between stops it.
- Sparkle's own checks stay on: `SUPublicEDKey`, `SUVerifyUpdateBeforeExtraction`, HTTPS. Automatic checks off: one
  schedule, ours.
- A custom `SPUUserDriver` draws our bar. Never a Sparkle window, never a restart while uploads or encodes run.
- The app is sandboxed, so Sparkle needs its installer XPC service (`SUEnableInstallerLauncherService`) and the two
  mach-lookup exceptions its documentation lists. The downloader service isn't needed: the app has network access.
  Signed inside out, without `--deep` (Sparkle's own warning).
- `SUPublicEDKey` is the Apple release key. It can't be changed without a Developer ID, and needn't be: after a
  revocation our manifest check refuses everything that key signs.

## Open until tested on a real Mac

- Sparkle with an ad hoc signature **and** the sandbox: its sources accept ad hoc, but the installer service and App
  Management on a normal user's Mac aren't proven by a runner. If either fails, Studio for Mac ships the notice with the
  fixed link and Sparkle waits for K6.
- `scripts/release.sh` builds unsigned Studio with the Debug entitlements. A1 to A3 must not add a restricted entitlement.

## Conflicts

#97, #98 and #99 change `Localizable.strings`, `StudioBootstrap`, `Services`, `SharedViews`, `ViewerRootIOS/Mac` and
`TVViews`. A1 adds new files only (plus one line in `StudioBootstrap` and `Package.swift`). A2 starts after those three
merge. #34 to #43 also touch Studio; A2 and A3 rebase on whichever is in.
