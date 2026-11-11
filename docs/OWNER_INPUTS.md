# What the owner needs to provide

CI builds unsigned until these exist. Nothing here is committed to the repo; values go in GitHub Actions secrets.

## Apple Developer (organisation, needs a D-U-N-S number)

| Item | Where it goes |
|---|---|
| Team ID | Secret `APPLE_TEAM_ID` |
| App Store Connect API key (App Manager role): Key ID, Issuer ID, `.p8` content | Secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` |
| Certificate storage for Fastlane match: a private repo and passphrase, or Xcode Cloud managed signing | Secrets `MATCH_GIT_URL`, `MATCH_PASSWORD` |
| Developer ID certificate, for the notarised macOS DMG | Via match |

## Bundle IDs to confirm and register

`net.alummahnow.viewer`, `net.alummahnow.viewer.tv`, `net.alummahnow.viewer.mac`, `net.alummahnow.studio`,
`net.alummahnow.studio.mac`, plus the same IDs with `.qa`.

## Native OAuth clients (Epic 9): done

Registered in AlUmmahNowAuth migration `0013_native_clients` (public PKCE clients, not secrets). Studio uses
`alummahnow-studio://auth/callback`; the client ids per environment and platform are in `Configs/*.xcconfig`.

## Decisions that block later work

D2 video delivery, D3 live provider (Go Live), D6 fonts, D10 transcription location, D11 who encodes renditions.
