//
//  NowPlayingSource.swift
//  Lyrical
//
//  The seam between the store and Spotify. SpotifyBridge is the real one; the
//  mock (LYRICAL_MOCK=1) fakes a three-track playlist advancing in real time,
//  which is how the wallpaper gets built and demoed without
//  Spotify installed and without ever triggering an automation prompt. The mock
//  draws its own covers into the artwork cache, so it needs no network either.
//

import AppKit

protocol NowPlayingSource: AnyObject, Sendable {
    func availability() -> SpotifyAvailability
    func snapshot() async throws -> NowPlayingSnapshot
    func send(_ command: TransportCommand) async throws
}

final class MockNowPlayingSource: NowPlayingSource, @unchecked Sendable {

    // Invented songs by invented artists. MockLyricsProvider keys its fake
    // lyrics on these ids; nothing here may be a real recording. Short
    // durations so a demo cycles through every wallpaper state in ~3 minutes.
    private static let tracks: [TrackInfo] = [
        TrackInfo(id: "spotify:track:lyricalmock0001",
                  name: "Paper Lanterns", artist: "The Placeholders",
                  album: "Demo Reel", duration: 64,
                  artworkURL: URL(string: "lyrical-mock://artwork/lyricalmock000000000000000000000001"),
                  isAd: false),
        TrackInfo(id: "spotify:track:lyricalmock0002",
                  name: "Northbound Static", artist: "Mock Orchestra",
                  album: "Test Pattern", duration: 52,
                  artworkURL: URL(string: "lyrical-mock://artwork/lyricalmock000000000000000000000002"),
                  isAd: false),
        TrackInfo(id: "spotify:track:lyricalmock0003",
                  name: "Untitled Hum", artist: "Nobody In Particular",
                  album: "Silence Study", duration: 20,
                  artworkURL: URL(string: "lyrical-mock://artwork/lyricalmock000000000000000000000003"),
                  isAd: false),
        TrackInfo(id: "spotify:track:lyricalmock0004",
                  name: "Lost in the Cache", artist: "The 404s",
                  album: "Not Found", duration: 20,
                  artworkURL: URL(string: "lyrical-mock://artwork/lyricalmock000000000000000000000004"),
                  isAd: false)
    ]

    private let seeding: Task<Void, Never>
    private let lock = NSLock()
    private var index = 0
    private var anchorPosition: TimeInterval = 0
    private var anchorUptime = ProcessInfo.processInfo.systemUptime
    private var isPlaying = true

    init() {
        // Detached so the drawing never runs on the main actor that built us. Only
        // mock mode constructs this type, so a normal launch does none of this.
        let hashes = Self.tracks.compactMap { $0.artworkURL.flatMap(ArtworkCache.hash(from:)) }
        seeding = Task.detached(priority: .utility) { await MockArtwork.seed(hashes: hashes) }
    }

    func availability() -> SpotifyAvailability { .running }

    // The locking lives in sync helpers: NSLock is `noasync` in Swift 6, and
    // there's nothing to await here anyway.
    func snapshot() async throws -> NowPlayingSnapshot {
        // Makes the very first poll wait for the covers to hit disk; every later
        // call is awaiting a task that already finished.
        await seeding.value
        return current()
    }

    func send(_ command: TransportCommand) async throws { apply(command) }

    private func current() -> NowPlayingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        advance()
        return NowPlayingSnapshot(state: isPlaying ? .playing : .paused,
                                  position: anchorPosition,
                                  track: Self.tracks[index])
    }

    private func apply(_ command: TransportCommand) {
        lock.lock()
        defer { lock.unlock() }
        advance()

        switch command {
        case .playPause:
            isPlaying.toggle()
        case .next:
            index = (index + 1) % Self.tracks.count
            anchorPosition = 0
        case .previous:
            index = (index + Self.tracks.count - 1) % Self.tracks.count
            anchorPosition = 0
        case .seek(let position):
            anchorPosition = min(max(position, 0), Self.tracks[index].duration)
        }
    }

    /// Rolls the playhead forward to now, wrapping into the next track(s). Lock held.
    private func advance() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { anchorUptime = now }
        guard isPlaying else { return }

        var position = anchorPosition + (now - anchorUptime)
        while Self.tracks[index].duration > 0, position >= Self.tracks[index].duration {
            position -= Self.tracks[index].duration
            index = (index + 1) % Self.tracks.count
        }
        anchorPosition = position
    }
}

/// Procedurally drawn stand-in covers, written into the artwork cache under the
/// hashes the mock's `artworkURL`s carry. The normal disk tier then serves them
/// and the pipeline runs end to end with no CDN involved.
private enum MockArtwork {

    static func seed(hashes: [String]) async {
        let cache = ArtworkCache(directory: ArtworkCache.defaultDirectory)
        for (index, hash) in hashes.enumerated() {
            guard let data = cover(index: index, of: hashes.count) else {
                NSLog("[Lyrical] mock artwork render failed for %@", hash)
                continue
            }
            // store() creates the directory, writes atomically and logs on failure;
            // a failed write just leaves the fallback gradient on screen.
            await cache.store(data, forHash: hash)
        }
    }

    private static let side = 640

    /// Distinct hue per track plus `index + 1` marker dots, so the three are
    /// tellable apart at a glance.
    private static func cover(index: Int, of count: Int) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        let full = CGFloat(side)
        let hue = CGFloat(index) / CGFloat(max(count, 1))
        let top = NSColor(colorSpace: .sRGB, hue: hue,
                          saturation: 0.55, brightness: 0.92, alpha: 1)
        let bottom = NSColor(colorSpace: .sRGB, hue: (hue + 0.11).truncatingRemainder(dividingBy: 1),
                             saturation: 0.85, brightness: 0.26, alpha: 1)

        if let gradient = CGGradient(colorsSpace: space,
                                     colors: [top.cgColor, bottom.cgColor] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: full),
                                       end: CGPoint(x: full, y: 0),
                                       options: [])
        }

        context.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
        context.setLineWidth(full * 0.045)
        context.strokeEllipse(in: CGRect(x: full * 0.20, y: full * 0.20,
                                         width: full * 0.60, height: full * 0.60))

        context.setFillColor(NSColor(white: 1, alpha: 0.9).cgColor)
        context.fillEllipse(in: CGRect(x: full * 0.43, y: full * 0.43,
                                       width: full * 0.14, height: full * 0.14))

        let dot = full * 0.06
        for marker in 0...index {
            context.fill(CGRect(x: full * 0.12 + CGFloat(marker) * dot * 1.8, y: full * 0.12,
                                width: dot, height: dot))
        }

        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
