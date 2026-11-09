# Theme audit: Apple apps (iOS, iPadOS, tvOS, macOS)

Audited against the four web theme demos (Fawanees, Lantern, Zujaj, Nahas) at `/en` and `/ar`, light and dark:
home, watch with the player controls and settings menu, channel and sign-in. Reference: `proto/theme-demos`
in the monorepo (`apps/web/src/theme/materials/*.css`, `system.css`, `pages.css`) and the player tokens in
`packages/fanous-tokens/themes/<theme>/player.json` (#472).

Baseline: `main` at e1777cb.

## Tokens and theme plumbing

| # | Defect | Where |
|---|---|---|
| A1 | Colours are an 8-entry placeholder palette from spec §3, typed by hand. None of the 38 semantic colours, 100+ component parts or the four themes exist. | `Packages/AUNDesign/Sources/AUNDesign/Fanous.swift` |
| A2 | Only one theme. The site theme an admin picks (`site.theme`, #492) is never read, cached or applied; there is no Fawanees fallback. | `AUNDesign` |
| A3 | No materials: no page wash, card gradient, gilded or glass border, edge highlight, glow, primary gradient, raised surface or player ring. Everything is a flat fill, which is the recolour the web redesign replaced. | all views |
| A4 | No per-theme shape: radii are literals (`10`, `4`) and do not follow the themes (Zujaj 3/6/8/12, Nahas 4/10/12/16, Fawanees 6/10/14/22, Lantern 6/10/14/20). | `SharedViews.swift`, `Components.swift` |
| A5 | No per-theme type: Zujaj (Inter, Noto Kufi Arabic) and Nahas (Source Serif 4, Amiri) render in SF. | everywhere |
| A6 | `.tint(Fanous.accent)` is the only accent, so system controls take raw `#FFA037`; gold text on parchment fails AA (2.0:1). | `AppSettings.swift` `fanousRoot` |
| A7 | No motifs: no theme pattern, sign-in header graphic or theme loader. | all |
| A8 | The token contrast test checks the placeholder palette, not the generated themes. | `AUNDesignTests/DesignTests.swift` |

## Player and controls (iOS, iPadOS, macOS)

| # | Defect | Where |
|---|---|---|
| P1 | The picture uses AVKit's system chrome (`AVPlayerViewController`, `AVPlayerView .floating`): grey translucent bar, white scrubber, no theme bar, played gradient, glowing handle, big play button or ring. | `AUNPlayer/PlayerSurface.swift` |
| P2 | A second, unrelated control row sits below the video (skip, quality, speed, subtitles, AirPlay) in `textPrimary` with SF Symbols at `.title3`; it duplicates AVKit's controls and none of it is themed. | `AUNPlayer/PlayerControlsBar.swift`, `WatchView.swift` |
| P3 | Player frame has no radius or theme ring (web: one clip, `--m-player` ring and glow per theme). | `WatchView.playerArea` |
| P4 | Settings menus are system `Menu`s: no theme menu surface, hover, selected row or accent check. | `PlayerControlsBar.swift` |
| P5 | No time pill, no tooltips, no buffered track, no live badge; error is a red footnote under the player instead of the theme error panel inside it. | `WatchView.swift` |
| P6 | No test that control icons are optically centred in their hit targets. | tests |

## Lists and cards (home rails, related)

| # | Defect | Where |
|---|---|---|
| L1 | Thumbnail placeholder is flat `surface`; web uses the theme hero gradient with a 1px divider ring and a theme glow ring on hover/focus. | `Components.swift` `ThumbnailImage` |
| L2 | Duration badge is `background @ 85%` with `textPrimary`; web uses the shared dark badge `rgb(9 21 30/.95)` with white text. In light themes the badge turns parchment. | `SharedViews.swift` |
| L3 | Rail header has no theme divider (web: primary-edge to divider gradient underline). | `RailHeader` |
| L4 | Page background is flat `background`; web has the per-theme page wash (radial glows over a hero-to-background gradient). | `HomeRailsContent`, `WatchView` |
| L5 | No featured hero card at the top of home (web: `--m-hero` card with gilded border, `Featured` tag and `Watch now` primary button). | `HomeView.swift` |
| L6 | Chapter rows are plain text; web chapters are rows with a theme hover and the accent time. Timestamp colour `accentText` (#FFC46B) on parchment fails AA. | `WatchView.WatchDetails` |

## Channel and sign-in

| # | Defect | Where |
|---|---|---|
| C1 | No channel screen exists in the Apple viewer; the channel name on cards and watch is plain metadata text. The web channel header (hero material, masked banner, avatar ring, sticky tab bar) has no native counterpart to theme. | `AUNFeatures` |
| S1 | No sign-in screen exists. The plan keeps `GuestAuthSession` until the native PKCE client is registered (`docs/PLAN.md` §2). Web sign-in: theme auth header graphic, raised card, primary `Continue`. | `AUNCoreBridge/Services.swift` |

## Settings, empty, loading, error

| # | Defect | Where |
|---|---|---|
| E1 | Settings is a toolbar gear `Menu` with system pickers; there is no theme row and none is needed (the theme is the admin's), but the menu has no theme surface. | `SharedViews.swift` `SettingsMenu` |
| E2 | Loading is the system `ProgressView`; web uses the theme loader (lantern flame, Zujaj glass, Nahas brass) and skeleton cards with a shine. | `HomeView`, `WatchView` |
| E3 | Error is plain text and `.borderedProminent` (system blue tinted orange); web uses the empty-state layout (icon, title, body) and the theme primary button. | `Components.swift` `ErrorStateView` |
| E4 | Empty home is a single secondary line. | `HomeView` |
| E5 | "Not ready" video is flat `surface` with text. | `WatchView.playerArea` |

## tvOS

| # | Defect | Where |
|---|---|---|
| T1 | Focus uses the system lift with no theme focus ring or glow; cards are untinted. | `TVViews.swift` |
| T2 | Background flat; no page wash; rail headers unthemed. | `TVViews.swift` |
| T3 | Player keeps the system transport bar, which is correct on tvOS (Siri Remote gestures); the custom menus are system `UIMenu`s. The surrounding watch page is unthemed. | `PlayerSurface.swift` |

## Studio (iOS, macOS)

| # | Defect | Where |
|---|---|---|
| ST1 | Studio screens use system styling with literal timeline colours. | `AUNStudio/*Views.swift`, `EditorMac.swift` |

## Accessibility and RTL

| # | Defect | Where |
|---|---|---|
| X1 | Snapshot tests cover only the placeholder palette: 2 screens × en/ar × light/dark. No theme × mode × language matrix. | `AUNFeaturesTests/SnapshotTests.swift` |
| X2 | Gold primary-action text is not checked; `onAccent` night on `#FFA037` passes, but the tint makes gold text on light surfaces. | `Fanous.swift` |
