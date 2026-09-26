//
//  LyricsWallpaperView.swift
//  Lyrical
//
//  Contents of each desktop-level window: backdrop plus either the carousel
//  or the title card. Everything fades out when Spotify quits, leaving the
//  user's real wallpaper. Screen size comes from the window, as in CoverWall.
//

import SwiftUI

struct LyricsWallpaperView: View {
    let nowPlaying: NowPlayingStore
    let lyrics: LyricsStore
    let palette: PaletteStore
    var config: LyricalConfig
    var screenSize: CGSize

    private var isVisible: Bool {
        nowPlaying.availability == .running && lyrics.track != nil
    }

    /// Changes on a new track or when switching between carousel and card,
    /// and that change is what triggers the crossfade.
    private var foregroundIdentity: String {
        let id = lyrics.track?.id ?? "none"
        if case .loaded(.synced) = lyrics.state { return "lyrics:\(id)" }
        return "card:\(id)"
    }

    var body: some View {
        let metrics = CarouselMetrics(config: config, screenSize: screenSize)
        let crossfade = Animation.easeInOut(duration: max(config.crossfadeDuration, 0))

        ZStack {
            if isVisible {
                ZStack {
                    GradientBackdrop(palette: palette.palette)
                        .id(palette.palette?.key ?? "none")
                        .transition(.opacity)

                    foreground(metrics)
                        .id(foregroundIdentity)
                        .transition(.opacity)
                }
                .transition(.opacity)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .ignoresSafeArea()
        .animation(crossfade, value: palette.palette?.key)
        .animation(crossfade, value: foregroundIdentity)
        .animation(.easeInOut(duration: 0.8), value: isVisible)
    }

    @ViewBuilder
    private func foreground(_ metrics: CarouselMetrics) -> some View {
        if case .loaded(.synced(let lines)) = lyrics.state {
            // A whole song is far taller than the screen. Pin the carousel to
            // exactly the screen, top-aligned, so the overflow hangs off the
            // bottom; left flexible, it would grow the ZStack and the fixed
            // outer frame would centre it, lifting the lit line off-screen.
            LyricsCarouselView(lines: lines, activeIndex: lyrics.activeIndex, move: lyrics.lastMove,
                               isPlaying: lyrics.isPlaying, metrics: metrics)
                .frame(width: screenSize.width, height: screenSize.height, alignment: .top)
        } else {
            TitleCardView(track: lyrics.track, status: LyricsStatusText.titleCard(for: lyrics.state),
                          metrics: metrics)
        }
    }
}
