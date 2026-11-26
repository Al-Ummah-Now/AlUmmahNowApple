# App Privacy answers (App Store Connect → App → App Privacy)

Drawn from the code; each answer names its source. The machine-readable copy is [`app-privacy.json`](app-privacy.json)
(CI checks the cited files exist: `scripts/check-store-metadata.py`). Update both when a feature adds a network call,
sign-in or an SDK. App Store Connect has no API for these answers that works with the team API key, so they are entered
by hand once per app record.

**Tracking: No, for every app.** No app links an analytics, advertising or attribution SDK (`project.yml`,
`Packages/AUNCoreKit/Package.swift`: Apple frameworks and aun-core only), and nothing is shared with data brokers or
for advertising.

**Privacy manifests.** Each app target carries `Apps/<target>/PrivacyInfo.xcprivacy` with the same collected data types
as below and its required-reason APIs: UserDefaults (`CA92.1`) in every app, and in Studio and Admin, which link
aun-core (Rust: file metadata through `stat`, a monotonic clock for timeouts), file timestamps (`C617.1`) and system boot
time (`35F9.1`). CI (`scripts/check-store-metadata.py`) fails if a manifest is missing, tracks, lacks those reasons, or
lists other data types than `app-privacy.json`. A feature that checks free disk space (offline downloads) adds the disk
space category (`E174.1`) in the same PR.

## Al Ummah Now (iPhone and iPad, Apple TV, Mac)

**Data Not Linked to You**, used for **App Functionality** only, none for tracking:

| App Store Connect data type | Why | Source |
|---|---|---|
| Identifiers → **Device ID** | While watching a live stream, the viewer sends a random per-view UUID (`viewerId`) in the live-viewer heartbeat (`POST /api/live-streams/:id/viewers`) so the server can deduplicate concurrent viewer counts; the server keeps it in memory for up to ~75 s across requests (longer than servicing a single request in real time) and does not link it to an account or device hardware. Sent by iPhone, iPad, Apple TV, and Mac. | `Live.swift`, `Packages/AUNFeatures/Sources/AUNFeatures/Live/LiveModels.swift`, `Packages/AUNFeatures/Sources/AUNFeatures/Live/LiveViews.swift` |

Not collected:

| Question | Answer | Source |
|---|---|---|
| Account, name, email, user ID | None: the viewer has no sign-in (`GuestAuthSession`) | `Packages/AUNCoreBridge/Sources/AUNCoreBridge/Services.swift` |
| Watch history, views, usage | Not sent: catalog and subtitle reads are GETs without an account; playback is AVPlayer streaming | `NativeCatalogService.swift`, `Packages/AUNPlayer/Sources/AUNPlayer/PlayerController.swift` |
| Site theme | Read from the public admin-api endpoint; nothing sent | `SiteTheme.swift` |
| App Attest / hardware device IDs | None: the viewer uses no App Attest, IDFV, or IDFA | `Packages/AUNFeatures/Sources/AUNFeatures/ViewerBootstrap.swift` |
| Crash and diagnostic data | Not sent: `AUNLog` writes to the device's own log only | `AppEnvironment.swift` |
| Settings (language, theme) | Kept on the device | `Packages/AUNDesign/Sources/AUNDesign/AppSettings.swift` |
| Where the last video stopped | Kept on the device, one entry, for coming back to it | `Packages/AUNPlayer/Sources/AUNPlayer/PlaybackPositionStore.swift` |

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
