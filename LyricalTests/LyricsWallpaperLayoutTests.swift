//
//  LyricsWallpaperLayoutTests.swift
//  LyricalTests
//
//  Regression: a real song's carousel is several screens tall. Left flexible,
//  it grew the wallpaper's ZStack and the fixed outer frame centred that, so
//  the lit line was drawn far above the screen and only the backdrop showed.
//  Short fixtures fit on one screen, which is why nothing else caught it.
//

import SwiftUI
import XCTest
@testable import Lyrical

private final class RunningSource: NowPlayingSource, @unchecked Sendable {
    func availability() -> SpotifyAvailability { .running }
    func snapshot() async throws -> NowPlayingSnapshot { .idle }
    func send(_ command: TransportCommand) async throws {}
}

private struct FixedLyrics: LyricsProviding {
    let lines: [LyricLine]
    func lyrics(for track: TrackInfo) async -> LyricsResult { .synced(lines) }
    func invalidate(trackID: String) async {}
}

@MainActor
final class LyricsWallpaperLayoutTests: XCTestCase {

    private let screen = CGSize(width: 1440, height: 900)

    private func brightPixelsNearAnchor(lineCount: Int) async throws -> Int {
        let config = ConfigStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lyrical-layout-\(UUID().uuidString).json"))
        let lines = (0..<lineCount).map { LyricLine(time: Double($0) * 4, text: "Line number \($0)", isGap: false) }
        let lyrics = LyricsStore(provider: FixedLyrics(lines: lines), offset: { 0 })
        let track = TrackInfo(id: "spotify:track:layout", name: "Song", artist: "Artist", album: "Album",
                              duration: Double(lineCount) * 4, artworkURL: nil, isAd: false)
        lyrics.setTrack(track)
        let artwork = ArtworkStore(config: config)
        defer { artwork.stop() }
        artwork.setTrack(track)   // no artwork URL: the fallback gradient, synchronously
        await lyrics.waitForPendingFetch()
        guard case .loaded(.synced) = lyrics.state else { throw XCTSkip("lyrics did not load") }

        let view = LyricsWallpaperView(nowPlaying: NowPlayingStore(config: config, source: RunningSource()),
                                       lyrics: lyrics, artwork: artwork,
                                       config: LyricalConfig(), screenSize: screen, surface: .lockScreen)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)

        // Before playback, line 0 is centred on anchorY. Look for white text there;
        // the fallback gradient is well below this brightness.
        let metrics = CarouselMetrics(config: LyricalConfig(), screenSize: screen)
        let band = Int(metrics.anchorY - metrics.fontSize)..<Int(metrics.anchorY + metrics.fontSize)
        let rep = NSBitmapImageRep(cgImage: image)
        var bright = 0
        for y in band {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.brightnessComponent > 0.5 { bright += 1 }
            }
        }
        return bright
    }

    func testShortSongDrawsTextAtAnchor() async throws {
        let bright = try await brightPixelsNearAnchor(lineCount: 3)
        XCTAssertGreaterThan(bright, 0)
    }

    func testFullLengthSongStillDrawsTextAtAnchor() async throws {
        let bright = try await brightPixelsNearAnchor(lineCount: 80)
        XCTAssertGreaterThan(bright, 0, "the lit line must be on screen, not pushed above it")
    }
}
