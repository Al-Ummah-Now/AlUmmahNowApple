# App Privacy answers (App Store Connect → App → App Privacy)

Drawn from the code; each answer names its source. The machine-readable copy is [`app-privacy.json`](app-privacy.json)
(CI checks the cited files exist: `scripts/check-store-metadata.py`). Update both when a feature adds a network call,
sign-in or an SDK. App Store Connect has no API for these answers that works with the team API key, so they are entered
by hand once per app record.

**Tracking: No, for every app.** No app links an analytics, advertising or attribution SDK (`project.yml`,
`Packages/AUNCoreKit/Package.swift`: Apple frameworks and aun-core only), and nothing is shared with data brokers or
for advertising.

## Al Ummah Now (iPhone and iPad, Apple TV, Mac)

**Data Not Collected.**

| Question | Answer | Source |
|---|---|---|
| Account, name, email, user ID | None: the viewer has no sign-in (`GuestAuthSession`) | `Packages/AUNCoreBridge/Sources/AUNCoreBridge/Services.swift` |
| Watch history, views, usage | Not sent: catalog and subtitle reads are GETs without an account; playback is AVPlayer streaming | `NativeCatalogService.swift`, `Packages/AUNPlayer/Sources/AUNPlayer/PlayerController.swift` |
| Site theme | Read from the public admin-api endpoint; nothing sent | `SiteTheme.swift` |
| Device identifiers | None (no App Attest: the viewer makes no writes) | `Packages/AUNFeatures/Sources/AUNFeatures/ViewerBootstrap.swift` |
| Crash and diagnostic data | Not sent: `AUNLog` writes to the device's own log only | `AppEnvironment.swift` |
| Settings (language, theme) | Kept on the device | `Packages/AUNDesign/Sources/AUNDesign/AppSettings.swift` |

## Al Ummah Now Studio (iPhone and iPad, Mac)

**Data Linked to You**, every type used for **App Functionality** only, none for tracking:

| App Store Connect data type | Why | Source |
|---|---|---|
| Contact Info → **Email Address** | Sign-in (OAuth, `email` scope) returns the account's email, shown in the account switcher | `Packages/AUNCoreKit/Sources/AUNCoreKit/CoreAccountService.swift`, `Studio/Accounts.swift` |
| Contact Info → **Name** | The account's display name (`profile` scope), shown in the account switcher | same |
| Identifiers → **User ID** | Every Studio request carries the account's token; the account id keys tokens and per-account choices | `Studio/StudioService.swift`, `AUNCoreKit/KeychainStorage.swift` |
| User Content → **Photos or Videos** | Videos the creator picks are uploaded to their channel | `Studio/TUSTransfer.swift`, `AUNStudio/Upload/UploadView.swift` |
| User Content → **Other User Content** | Titles, descriptions, tags, categories, playlists, schedules | `Studio/UploadModels.swift`, `Studio/ContentModels.swift` |
| Identifiers → **Device ID** (iPhone and iPad only) | Only once videos admin turns Apple attestation on: an App Attest key id and assertions prove writes come from the genuine app (fraud prevention); the proof is bound to the signed-in account | `AUNCoreBridge/Attestation.swift`, `AUNCoreKit/StudioBootstrap.swift` |

Not collected: **Search History** (Studio's suggestions are answered in real time; api-videos `search.router.ts` stores no
query: `CoreSearchService.swift`), **Usage Data** (Analytics reads the channel's own numbers; the app reports no usage:
`Studio/AnalyticsModels.swift`), **Diagnostics** (device log only), **Location, Contacts, Health, Financial, Browsing
History, Purchases** (never read). Studio for Mac has no App Attest, so no Device ID.

Paths without a folder are under `Packages/AUNCoreBridge/Sources/AUNCoreBridge/`.
