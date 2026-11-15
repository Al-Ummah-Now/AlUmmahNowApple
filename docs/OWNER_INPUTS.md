# What the owner needs to provide

CI builds unsigned until these exist. Nothing here is committed to the repo; values go in GitHub Actions secrets.

## Store release (NAT-REL): the full list is in `docs/RELEASING.md` → "Owner checklist (Apple)"

The pipeline, listings, screenshots, App Privacy answers, universal links and App Attest are built; a tag builds
everything unsigned until these exist, and each one unlocks its step on the next tag:

1. Apple Developer Program for the organisation (D-U-N-S number) → **Team ID**.
2. App Store Connect **team API key, role Admin** → secrets `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`,
   `ASC_KEY_P8` (optional `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD` for Studio for Mac).
3. App IDs and capabilities (Xcode creates them through the key, else by hand): Associated Domains on the viewer
   (iOS, Mac) and Studio (iOS, Mac) ids; App Attest on `net.alummahnow.studio`(`.qa`).
4. App Store Connect records: Al Ummah Now (iOS), Al Ummah Now TV (tvOS), Al Ummah Now for Mac (macOS), Al Ummah Now
   Studio (iOS), and the four QA records; TestFlight groups; App Privacy from `store/apple/app-privacy.md`.
5. Optional: repository variable `APPLE_LISTINGS` (e.g. `viewer-ios,viewer-tv,viewer-mac,studio-ios`) to upload the
   store texts and screenshots with each tag.
6. videos admin → Mobile apps: the **Team ID** (turns on universal links), then **App Attest on** once a signed Studio
   build is in TestFlight.
7. Review and merge the app icon PR (App Store Connect rejects uploads without icons).
8. A privacy policy page, when one is published: its address goes in `store/apple/*/metadata/*/privacy_url.txt`
   (today they point at the videos site's Privacy & data page).

## Bundle IDs

`net.alummahnow.viewer`, `net.alummahnow.viewer.tv`, `net.alummahnow.viewer.mac`, `net.alummahnow.studio`,
`net.alummahnow.studio.mac`, plus the same IDs with `.qa`.

Admin (staff only, TestFlight internal): `net.alummahnow.admin`, `net.alummahnow.admin.mac` and the `.qa` ids, each
with Push Notifications and Time Sensitive Notifications, App Store Connect records and an APNs `.p8` key. Full list:
`docs/RELEASING.md`, "Releasing Al Ummah Now Admin".

## Native OAuth clients (Epic 9): done

Registered in AlUmmahNowAuth migration `0013_native_clients` (public PKCE clients, not secrets). Studio uses
`alummahnow-studio://auth/callback`; the client ids per environment and platform are in `Configs/*.xcconfig`.
The Admin app's "Admin (iOS)" and "Admin (macOS)" clients (`alummahnow-admin://auth/callback`) are in AlUmmahNowAuth
migration `0036_admin_native_clients`.

## Decisions that block later work

D2 video delivery, D3 live provider (Go Live), D6 fonts, D10 transcription location, D11 who encodes renditions.
