# Lyrical

Your Mac, singing along. While you're using it, Lyrical paints the album art
of whatever the Spotify app is playing onto the desktop, CoverWall-style: the
cover, crisp and centred, over a blurred, dimmed copy of itself. Lock the
screen and the same backdrop stays put while the cover gives way to the
time-synced lyrics, gliding up an Apple Music-style carousel under a clock.

- CoverWall's control bar floats over the desktop: track, a draggable
  progress bar, and previous / play-pause / next. Clicking it never pulls
  focus from the app you're in.
- Lives in the menu bar: no Dock icon, no windows to manage.
- Fully click-through: desktop icons, drag-select and right-click still work.
- Lyrics only on the lock screen. They cover the system's password prompt
  while music plays, but Touch ID and typing your password work as usual.
- Lyrics come from [LRCLIB](https://lrclib.net), a free, open lyrics
  database. No account or API key.
- Words swell and glow as they're sung, on real word timing where it
  exists: LRCLIB's word-synced Lyricsfiles, or NetEase Cloud Music's
  word-by-word lyrics laid onto LRCLIB's lines (about 93% of lines in
  testing). Otherwise the timing is estimated from syllables and the gap to
  the next line, using a model fitted to ~17,000 real word stamps.
- Light on CPU: only the lit line redraws, and only while music plays.
  Set `animateWords` to `false` for zero CPU between lines. The progress
  bar redraws only when it visibly moves (a pixel, or a second on the
  clock), nothing redraws while the displays sleep, and Low Power Mode
  halves the lock screen's frame rate. Spotify is asked for three values a
  second, and for the full track only when it changes.

Requires macOS 26 and the Spotify desktop app. Sibling of
[CoverWall](https://github.com/adripoli/CoverWall).

## Install

```sh
brew install xcodegen      # once
make run                   # builds, installs to /Applications, launches
```

On first launch macOS asks for **Automation** access to Spotify. Lyrical only
reads what's playing. If you declined, use the menu's **Grant Automation
Access…**. Ad-hoc builds lose that grant on every rebuild; reset it with
`tccutil reset AppleEvents com.lyrical.app`.

## Menu

| Item | Does |
|---|---|
| Show Album Art | Hide or show the album art on the desktop |
| Show Controls | Hide or show the progress bar and transport buttons |
| Show Lyrics on Lock Screen | Hide or show the lyrics while the screen is locked |
| Displays | All displays, or the main one only |
| Lyrics Earlier / Later | Shift timing by 0.25 s if a song feels out of sync |
| Reset Timing | Back to the default +0.25 s lead |
| Reload Lyrics | Forget the cached lyrics for this song and look again |
| Open Config… | Opens `~/.config/lyrical/config.json` |

## Config

`~/.config/lyrical/config.json` is hot-reloaded from the menu (**Reload
Config**). Missing keys use their defaults, and a broken file falls back to
defaults rather than crashing.

| Key | Default | |
|---|---|---|
| `displays` | `"all"` | `"all"` or `"main"` |
| `lyricsOffset` | `0.25` | seconds; positive shows each line earlier |
| `fontSizeFraction` | `0.045` | lit-line size as a fraction of screen height |
| `fontDesign` | `"default"` | `"default"`, `"rounded"`, `"serif"` |
| `textAlignment` | `"center"` | `"center"` or `"leading"` |
| `columnWidthFraction` | `0.6` | lyrics column width, fraction of screen width |
| `anchorYFraction` | `0.5` | where the lit line sits, from the top |
| `blurInactive` | `true` | blur lines as they get further from the lit one |
| `animateWords` | `true` | each word grows and glows as it's sung (redraws the lit line every frame while playing) |
| `lookUpWordTiming` | `true` | look up real word timing on NetEase Cloud Music (sends the song's title and artist there) |
| `backdropBlurRadius` | `40` | blur of the full-screen backdrop, both surfaces |
| `backdropDim` | `0.35` | 0–1, black laid over the backdrop so white text reads |
| `coverHeightFraction` | `0.55` | desktop cover height, fraction of screen height |
| `crossfadeDuration` | `0.5` | seconds, between songs |
| `showWallpaper` | `true` | album art on the desktop |
| `showControls` | `true` | progress bar and transport buttons on the desktop |
| `controlBarWidth` | `520` | points |
| `controlBarBottomInset` | `24` | points above the Dock |
| `controlBarOpacity` / `controlBarHoverOpacity` | `0.7` / `1.0` | at rest / under the pointer |
| `controlPanelLevel` | `"aboveIcons"` | `aboveIcons` = clickable, over desktop icons. `belowNormal` = tucked under everything, effectively decorative |
| `showOnLockScreen` | `true` | lyrics over the lock screen (uses private SkyLight calls; off if macOS drops them) |
| `startAtLogin` | `true` | |
| `pollIntervalPlaying` / `pollIntervalPaused` | `1.0` / `5.0` | seconds between Spotify polls |

## When there are no lyrics

Instrumentals, songs LRCLIB doesn't have, ads, and offline moments show a
title card (song and artist) with a short note. Lookups that failed are
retried automatically. "Not found" is re-checked after a week, since LRCLIB
is crowd-sourced and grows.

## Development

```sh
make test                        # unit tests
make test-one T=LRCParserTests   # one test class
make app                         # build/Lyrical.app
LYRICAL_MOCK=1 build/Lyrical.app/Contents/MacOS/Lyrical
```

Word timing is measured, not eyeballed: `Scripts/word-timing-eval/fetch-corpus.py`
downloads ground truth (kept in `build/`, out of git), and
`Scripts/word-timing-eval/run.sh` scores the app's own timing code against it.

Mock mode plays an invented four-song playlist with invented lyrics. It needs
no Spotify, no network, and no permission prompt, and it runs through every
wallpaper state: intro dots, lyrics, a mid-song gap, a wrapped long line,
instrumental, and not-found.

Cutting a release: `git tag v0.1.0 && git push origin v0.1.0`. CI builds the
`.dmg` and `.zip` and attaches them to a GitHub release.
