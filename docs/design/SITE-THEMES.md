# Site themes in the Apple apps

## Spec

- The apps draw in the theme an admin sets for the whole site (`site.theme`, admin-api #492): Fawanees, Lantern,
  Zujaj or Nahas. There is no per-person theme picker. Light and dark stay per person (system, light or dark, in
  Settings), exactly as on the web.
- The theme is read from `GET {adminAPI}/public/site-theme` (`{"theme":"…"}`, public, `max-age=30`), cached in
  `UserDefaults`, and refreshed on launch and whenever the app becomes active. Offline with nothing cached, the
  apps show Fawanees, the site default. Unknown ids reduce to Fawanees, as the web does.
- Every colour, component part, material (page wash, card gradient and gilded or glass border, edges, glows,
  primary gradient, selected row, player ring), radius, typeface, motif and player-chrome value comes from
  `packages/fanous-tokens` in the monorepo through its native generator. Nothing is typed by hand here.
- Screens are designed per component, not recoloured: the web's material recipes (`fill padding-box, border
  border-box; box-shadow: edge`) are drawn natively by `FanousSurface`.
- RTL mirrors logical gradients (`to end`, `at start`) as the web does; Arabic uses its own type scale and, in
  Zujaj and Nahas, its own face (Noto Kufi Arabic, Amiri).
- Text passes WCAG AA in every theme and mode; gold primary-action text passes 7:1 on every stop of the primary
  gradient.

## Plan (one PR per area, stacked)

1. **Foundation** (this PR): vendored registry and motifs (`scripts/sync-fanous.sh`, pinned by `fanous.lock`,
   checked in CI), bundled OFL fonts, `SiteThemeServicing` + `SiteThemeStore`, `\.fanous` environment,
   `FanousSurface` material renderer, `Fanous.*` roles that follow the theme, tests and the snapshot matrix.
2. **Screens**: header, home hero and rails, video cards, states and skeletons, buttons, settings, watch details.
3. **Player**: themed chrome over AVPlayer (bar, scrubber, big play, time pill, settings menu, error panel, ring)
   with the ±1px icon centring test.
4. **tvOS and Studio**.

## Updating the themes

Change tokens in the monorepo, then bump `fanous.lock` to that commit and run `scripts/sync-fanous.sh`.
CI fails if the vendored files differ from the pinned commit.

## Tests

- `AUNCoreBridgeTests/SiteThemeServiceTests`: endpoint, errors, admin-api URL from Info.plist.
- `AUNDesignTests/SiteThemeStoreTests`: endpoint value is shown and cached; offline keeps the cache; no cache
  falls back to Fawanees; unknown values reduce to Fawanees; `-AUNSiteTheme` pins a theme for UI tests.
- `AUNDesignTests/DesignTests`: AA for every theme and mode, 7:1 gold primary text, CSS gradient geometry.
- `AUNFeaturesTests/SnapshotTests`: key screens × 4 themes × light/dark × en/ar, references recorded on the CI
  simulator.
