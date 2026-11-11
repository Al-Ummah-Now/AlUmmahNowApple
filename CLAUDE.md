# CLAUDE.md: Al Ummah Now Apple apps

Native viewer and Studio apps for iOS, iPadOS, tvOS and macOS. Swift + SwiftUI, AppKit on macOS where it is needed.
Product spec: `docs/native-apps/EPICS.md` in https://github.com/Al-Ummah-Now/AlUmmahNow. Plan: `docs/PLAN.md`.

## Commands
- `make generate`: create `AlUmmahNow.xcodeproj` from `project.yml` (the project is not committed).
- `make lint`, `make format`.
- `make test-ios | test-ipad | test-tvos | test-mac`, `make build-all` (these call `scripts/ci.sh`, the same as CI).
- Open `AlUmmahNow.xcworkspace`.

## Rules
- **Public repo.** Never commit secrets, certificates, provisioning profiles, API keys or `.env` files.
- **Small PRs into `main`, CI green**, then a rebase merge (`gh pr merge --rebase`), never squash: a squash commit is
  authored with the merger's account email. Commit as `meywd <3499969+meywd@users.noreply.github.com>`. Conventional
  commit titles.
- **No TODO/FIXME/HACK comments** (lint fails). Implement it or open a GitHub issue labelled `queue`.
- **No `print`.** Use `AUNLog` (os.Logger).
- **Every user-facing string goes through `L10n`**, with both `en` and `ar` entries in
  `Packages/AUNDesign/Sources/AUNDesign/Resources`. A test fails on missing keys.
- **Bilingual and RTL in every UI story**: leading/trailing only, snapshot en and ar, UI test in ar.
  Server content uses `*Localized` fields with fallback to the plain field.
- **Fanous tokens only** for colors (`Fanous.*`), no literals in views.
- **Autoplay of the next item stays off by default** (spec 21.6). No engagement dark patterns.
- **Every core call goes through a protocol in `AUNCoreBridge`**, so the Rust XCFramework can replace the temporary
  native implementation without touching features.
- **APIs must exist in the CI SDK** (Xcode 26.6, macos-26 runner). Local Xcode may be newer.
- **Never upload to TestFlight or the App Store by hand.** Releases are tag-triggered from `main` only (`docs/RELEASING.md`).
- Every feature is tier-aware once Epic 27 entitlements land; never hard-code plans. Never use Stripe.

## Layout
`Packages/AUNCoreBridge` models, protocols, temporary native services · `AUNDesign` Fanous tokens, L10n, components ·
`AUNPlayer` AVKit wrapper · `AUNFeatures` viewer screens · `AUNStudio` Studio engines and screens ·
`Apps/*` thin app targets · `UITests/*` XCUITest.
