//
//  LyricsWallpaperView.swift
//  Lyrical
//
//  Contents of each full-screen window. Both surfaces sit on CoverWall's
//  blurred-cover backdrop, so unlocking doesn't change the background. The
//  desktop shows the crisp album cover on it, as CoverWall does; the lyrics
//  (carousel or title card) and a clock only appear on the lock screen, since
//  the backdrop covers the system's clock there. Everything fades out when
//  Spotify quits, leaving the user's real wallpaper. Screen size comes from
//  the window, as in CoverWall.
//

import SwiftUI

struct LyricsWallpaperView: View {
    let nowPlaying: NowPlayingStore
    let lyrics: LyricsStore
    let artwork: ArtworkStore
    var config: LyricalConfig
    var screenSize: CGSize
    var surface: LyricsSurface = .desktop
    /// False while the displays sleep: the lit line and the gap dots then
    /// hold still instead of redrawing every frame for nobody.
    var isLive = true

    private var isVisible: Bool {
        nowPlaying.availability == .running && artwork.presentation != .none
    }

    private var artworkIdentity: String { ArtworkBackdrop.identity(of: artwork.presentation) }

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
                    ArtworkBackdrop(nowPlaying: nowPlaying, artwork: artwork, config: config,
                                    screenSize: screenSize, showsCover: surface == .desktop)

                    if surface == .lockScreen {
                        foreground(metrics)
                            .id(foregroundIdentity)
                            .transition(.opacity)

                        LockScreenClockView(screenSize: screenSize, design: metrics.fontDesign)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .ignoresSafeArea()
        // Nobody sees a spring or a fade while the displays sleep: lines and
        // covers change in one step instead of animating for nothing.
        .transaction { transaction in
            guard !isLive else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .animation(crossfade, value: artworkIdentity)
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
                               isPlaying: lyrics.isPlaying && isLive, metrics: metrics,
                               position: { [lyrics] in lyrics.singingPosition() })
                .frame(width: screenSize.width, height: screenSize.height, alignment: .top)
        } else {
            TitleCardView(track: lyrics.track, status: LyricsStatusText.titleCard(for: lyrics.state),
                          metrics: metrics)
        }
    }
}
