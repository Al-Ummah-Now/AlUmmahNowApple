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
