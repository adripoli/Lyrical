# Lyrical — design

A macOS menu-bar agent that turns the desktop background into the **time-synced
lyrics** of whatever the Spotify desktop app is playing. Lines glide past in an
Apple Music-style vertical carousel over a gradient taken from the album art.

Lyrical is a sibling of [CoverWall](https://github.com/adripoli/CoverWall) and
starts from its code and conventions.

## Goals

- Show the current song's synced lyrics on every desktop as a live wallpaper.
- Keep the active line in time with playback, including pauses and scrubs made
  in Spotify.
- Make it look calm and polished: a smooth spring carousel over a
  color-matched gradient.
- Stay out of the way: fully click-through, no Dock icon, near-zero CPU between
  lines.

## Non-goals

- Playback controls on the desktop. Transport stays in Spotify (or CoverWall).
- Players other than the Spotify desktop app.
- Word-by-word (karaoke) highlighting. LRCLIB data is line-level.
- Plain (unsynced) lyrics display. The data model keeps the state, but the UI
  shows the title card.
- App Store / sandboxed distribution.

## Conventions carried over from CoverWall

- XcodeGen `project.yml`; `make app | install | run | test | dmg`.
- `LSUIElement` agent (menu bar only), macOS 26 deployment, unsandboxed and
  unhardened for local builds.
- Hot-reloaded JSON config at `~/.config/lyrical/config.json` with per-key
  tolerant decoding, so a partial or stale file never breaks launch.
- Mock mode via `LYRICAL_MOCK=1`: fake tracks and fake lyrics, with no Spotify,
  network or permission prompt.
- Bundle id `com.lyrical.app`.

## Lyrics source: LRCLIB

Spotify's AppleScript dictionary exposes no lyrics. Lyrical uses
[LRCLIB](https://lrclib.net), which is free, needs no API key and returns
line-synced LRC. Rejected alternatives: Musixmatch (needs a paid key) and
Spotify's internal lyrics endpoint (needs the user's login cookie, breaks
without notice and violates the ToS).

No real lyric text is ever committed to the repo. The mock tracks and their
lyrics are invented.

## Architecture

```
Spotify.app ──AppleScript──▶ SpotifyBridge ─▶ NowPlayingStore (1 Hz poll + PlaybackClock interpolation)
                                                   │ track change
                          ┌────────────────────────┼─────────────────────────┐
                          ▼                        ▼                         ▼
                   LyricsStore               PaletteStore               OverlayManager
       (LRCLIB fetch → cache → LRCParser)  (artwork → dominant colors)   (1 LyricsWindow / screen)
                          │  activeIndex (timer to exact next line)       │
                          └──────────────▶ LyricsWallpaperView ◀─────────┘
                                     (GradientBackdrop + LyricsCarousel | TitleCard)
```

### Reused from CoverWall

Renames: `COVERWALL_` → `LYRICAL_`, `com.coverwall` → `com.lyrical`.

| Area | Files | Changes |
|---|---|---|
| Spotify | `SpotifyBridge`, `NowPlaying`, `NowPlayingParser`, `PlaybackClock`, `NowPlayingStore`, `AutomationPermission`, `NowPlayingSource` | The mock source gets invented tracks. Transport commands are dropped where nothing uses them. |
| Artwork | `ArtworkCache`, `ArtworkProvider`, `ArtworkRenderer.fallbackColors(seed:)` and `cgImage(from:)` | The blur pipeline is dropped. |
| Windows | `ArtworkWindow` → `LyricsWindow` | Same desktop window level, `ignoresMouseEvents`, `canJoinAllSpaces` / `stationary`. |
| App | `AppDelegate`, `OverlayManager`, `StatusBarController`, `main.swift` | `ControlPanelWindow` is removed; new menu items (below). |
| Config | `Config.swift` | New keys (below). |
| Build / ship | `project.yml`, `Makefile`, `Scripts/*`, `.github/workflows/release.yml`, `Support/Info.plist` | New icon glyph. Keeps `NSAppleEventsUsageDescription` and `LSUIElement`. |
| Tests | `PlaybackClockTests`, `NowPlayingParserTests`, `ConfigTests`, `SpotifyBridgeScriptTests` | `SpotifyBridgeScriptTests` compiles the real AppleScript and is kept deliberately. It caught CoverWall's reserved-word bug. |

### New units

**`Lyrics/LyricsModel.swift`**
- `LyricLine { time: TimeInterval, text: String, isGap: Bool }`
- `Lyrics { lines: [LyricLine] }`
- `LyricsState`: `idle`, `loading`, `synced(Lyrics)`, `plain(String)`,
  `instrumental`, `notFound`, `failed`, `advertisement`

**`Lyrics/LRCParser.swift`** is a pure function from LRC text to `[LyricLine]`.
- Accepts `[mm:ss]`, `[mm:ss.xx]` and `[mm:ss.xxx]`, and several timestamps on
  one line (`[00:12.00][01:30.00]chorus`).
- Applies the `[offset:±ms]` tag. A positive offset means lyrics appear
  earlier.
- Ignores metadata tags (`ar`, `ti`, `al`, `by`, `length`, `re`, `ve`).
- Handles `\n` and `\r\n`, and skips malformed lines.
- Timestamped lines with empty text become gap markers (`isGap = true`).
- Output is sorted by time and stable for equal times. Consecutive gaps are
  collapsed.

**`Lyrics/LRCLIBClient.swift`** has an injected `URLSession` and sends
`User-Agent: Lyrical/<version> (https://github.com/adripoli/Lyrical)` with a
10 s timeout.
1. `GET /api/get?track_name=&artist_name=&album_name=&duration=` (duration in
   whole seconds).
2. On 404, it calls `GET /api/search?track_name=&artist_name=` with a
   normalized title: it strips ` - Remastered…` / ` - Live…` style suffixes,
   `(feat. …)` / `(with …)` and `[…]`. It then picks the result with the
   closest `duration` within ±3 s, preferring results that have
   `syncedLyrics`.
3. The result maps to `LyricsState`:
   - `instrumental: true` → `.instrumental`
   - `syncedLyrics` → `.synced`
   - only `plainLyrics` → `.plain`
   - nothing → `.notFound`
   - transport or 5xx error → `.failed`

**`Lyrics/LyricsCache.swift`** stores JSON at
`~/Library/Caches/Lyrical/lyrics/<sanitized-track-id>.json`.
- Positive results (synced, plain, instrumental) never expire.
- `notFound` expires after 7 days, so new LRCLIB uploads get picked up.
- `failed` is never cached.
- A corrupt file is treated as a miss and deleted.

**`Lyrics/LyricsTimeline.swift`** is pure.
- `activeIndex(at position:, offset:) -> Int?` uses binary search over line
  times. It returns `nil` before the first line.
- `nextBoundary(after position:, offset:) -> TimeInterval?` returns the time of
  the next line.
- The effective position is `position + offset`. The default 0.25 s lead lets
  the spring settle on the beat.

**`Lyrics/LyricsStore.swift`** (`@MainActor @Observable`)
- Watches `NowPlayingStore` for track-id changes. It resolves lyrics by trying
  the cache, then the client, then storing the result.
- Cancels an in-flight fetch when the track changes, and drops late results by
  comparing track ids.
- Publishes `state`, `activeIndex` and `lastJumpWasSeek`.
- Runs a single `Task` that sleeps exactly until `nextBoundary`, so there's no
  per-frame work. The task re-arms on:
  - play/pause
  - a detected seek (`lastSeekDetectedAt`)
  - poll re-anchor drift
  - `lyricsOffset` changes
- Retries `.failed` with exponential backoff (5 s doubling, capped at 5 min)
  while the same track is current.
- Ads (`spotify:ad:`) become `.advertisement` with no network call.
- `reload()` clears the cache entry for the current track and fetches again.

**`Palette/PaletteExtractor.swift`** is pure CoreImage/CoreGraphics.
1. Downsamples the cover to 24×24 and buckets pixels by hue and brightness.
2. Picks 3–4 dominant, distinct colors.
3. Clamps their brightness to `backdropBrightnessCap` (default 0.35) and boosts
   saturation a little, so white text always reads.

A near-grayscale cover produces a dark neutral palette. If there's no artwork,
it falls back to `ArtworkRenderer.fallbackColors(seed: albumOrTrackId)`.

**`Palette/PaletteStore.swift`** loads artwork through `ArtworkProvider`,
extracts the palette off the main actor, and publishes it keyed by track.

**`UI/GradientBackdrop.swift`** is a 3×3 `MeshGradient` built from the palette.
Colors are placed so the darkest sits behind the text column. The backdrop
crossfades between tracks over `crossfadeDuration`. It's static and never
animates on its own.

**`UI/TitleCardView.swift`** shows the title (large) and artist, with a small
status line: "♪ Instrumental", "No lyrics found", "Couldn't reach LRCLIB",
"Advertisement", or a subtle "Loading lyrics…".

**`UI/LyricsWallpaperView.swift`** is the root view.
- Draws the backdrop, then either the carousel (`.synced`) or the title card
  (every other state).
- The foreground crossfades when the track id changes.
- The whole view fades out when Spotify isn't running, as CoverWall does.

**`UI/LyricsCarouselView.swift`** is described in the next section.

### Carousel

**Layout**
- A `VStack` of every line inside a column `columnWidthFraction` of the screen
  wide. Lines are centered or leading-aligned according to `textAlignment`.
- Text wraps. Each line's height is measured with `onGeometryChange`, and
  cumulative offsets give each line's midpoint.
- The stack is offset so the active line's midpoint sits at
  `anchorYFraction × screenHeight` (default 0.45). Before the first line,
  line 0 sits just below the anchor, and the intro dots (below) sit on the
  anchor.

**Per-line style by distance `d = |i − active|`**

| d | 0 | 1 | 2 | 3 | ≥4 |
|---|---|---|---|---|---|
| scale | 1.0 | 0.86 | 0.86 | 0.86 | 0.86 |
| opacity | 1.0 | 0.55 | 0.38 | 0.25 | 0.15 |
| blur (pt) | 0 | 0 | 1.2 | 2.4 | 3.6 |

- Blur is disabled entirely when `blurInactive = false`.
- The active line is bold and the others are semibold, with font size
  `fontSizeFraction × screenHeight` and design `fontDesign`.
- Scaling uses the line's alignment edge as its anchor.
- Only lines within ±10 of the active one render (the others are
  `opacity(0)` placeholders that keep their height), which bounds the blur
  cost.

**Motion**
- A normal advance of one line animates offset and style with
  `.spring(response: 0.55, dampingFraction: 0.85)`. Each line's animation is
  delayed by `0.035 × d`, which produces the "wave".
- A seek, or a jump of more than 3 lines, uses a 0.25 s ease-out with no
  stagger.
- Gap lines, and an intro of more than 4 s before the first line, render as
  three dots. The dots breathe (opacity pulse) only while that gap is active
  and Spotify is playing, and hold still otherwise.

**Cost**
- The view only changes when `activeIndex` changes. Between lines nothing
  renders except the breathing dots during gaps.
- This matters because occlusion-based throttling doesn't work for
  desktop-level windows (a known CoverWall limitation).

### Menu bar

- A now-playing line (`Title — Artist`, disabled) and a lyrics status:
  "Synced lyrics · LRCLIB", "Plain lyrics only", "No lyrics found",
  "Instrumental", "Loading…" or "Couldn't reach LRCLIB".
- Show Lyrics toggle (`showWallpaper`).
- Lyrics Earlier (−0.25 s), Lyrics Later (+0.25 s) and Reset Timing, which edit
  `lyricsOffset` and show the current value, e.g. "Timing: +0.25 s".
- Reload Lyrics, Open Config…, Start at Login, and Quit Lyrical.
- If automation is denied, a hint item opens the Automation pane in System
  Settings (reuses CoverWall's flow).

### Config (`~/.config/lyrical/config.json`)

| Key | Default | Notes |
|---|---|---|
| `displays` | `all` | `all` \| `main` |
| `showWallpaper` | `true` | |
| `startAtLogin` | `true` | |
| `pollIntervalPlaying` | `1.0` | seconds |
| `pollIntervalPaused` | `5.0` | seconds |
| `crossfadeDuration` | `0.5` | seconds |
| `lyricsOffset` | `0.25` | seconds; a positive value shows lines earlier |
| `fontSizeFraction` | `0.045` | of screen height |
| `fontDesign` | `default` | `default` \| `rounded` \| `serif` |
| `textAlignment` | `center` | `center` \| `leading` |
| `columnWidthFraction` | `0.6` | of screen width |
| `anchorYFraction` | `0.45` | from the top |
| `blurInactive` | `true` | |
| `backdropBrightnessCap` | `0.35` | 0…1 |

## Error and edge handling

| Situation | Behavior |
|---|---|
| Spotify not running | The wallpaper fades out, and no Apple Events are sent (CoverWall's guard). |
| Automation denied | The wallpaper shows the last known state; the menu shows a grant hint. |
| Offline or LRCLIB down | Title card "Couldn't reach LRCLIB"; backoff retry while the track is current. |
| Plain lyrics only | Title card "Plain lyrics only". |
| Ad | Title card "Advertisement"; no fetch. |
| Track changes mid-fetch | The fetch is cancelled; a stale result is dropped by track id. |
| Paused | The carousel holds the current line; dots stop breathing. |
| Scrub in Spotify | The seek is detected on the next poll (≤1 s); the carousel snaps with the quick ease. |
| Display added/removed, sleep/wake, Spaces | Handled by the reused `OverlayManager` reconciliation. |

## Testing

**Unit tests** (`make test`)

| Suite | Cases |
|---|---|
| `LRCParserTests` | all three timestamp precisions; multiple stamps per line; the `offset` tag (both signs); metadata ignored; gap markers; collapsing consecutive gaps; CRLF; malformed lines skipped; unsorted input sorted |
| `LyricsTimelineTests` | before the first line; exactly on a boundary; between lines; after the last line; offset shifting the boundary; `nextBoundary` at the end is `nil` |
| `LRCLIBClientTests` | uses a `URLProtocol` stub. Covers query parameters and User-Agent; `/get` success → synced; 404 → search fallback with a normalized title; closest-duration pick within ±3 s; synced-over-plain preference; instrumental; 5xx → failed |
| `TitleNormalizerTests` | remaster/live suffixes; feat/with parentheticals; brackets; titles left untouched |
| `LyricsCacheTests` | hit round-trip; notFound TTL expiry; failed not cached; corrupt file → miss; track-id sanitizing |
| `PaletteExtractorTests` | a solid color → that hue darkened to the cap; a two-color image → both hues; a grayscale image → neutral; brightness never above the cap |

Carried over: `PlaybackClockTests`, `NowPlayingParserTests`, `ConfigTests`
(adapted to the new keys) and `SpotifyBridgeScriptTests`.

**Mock mode:** with `LYRICAL_MOCK=1`, invented tracks with invented LRC advance
in real time. One track has an intro gap and a mid-song gap, one has no lyrics
(title card), and one is marked instrumental.

**Manual checklist** (real Spotify)
1. Lyrics stay in sync across a whole known song.
2. Scrubbing in Spotify snaps to the right line.
3. Pause holds the carousel; resume continues.
4. Earlier/Later nudges shift timing visibly.
5. A song missing from LRCLIB shows the title card.
6. Quitting Spotify fades the wallpaper out.
7. Desktop icons, drag-select and right-click still work (click-through).
8. Multi-display, Spaces switching, and sleep/wake.
9. Activity Monitor shows about 0% CPU while a line is held.
10. `make run` installs `/Applications/Lyrical.app` and the menu bar icon
    appears.
