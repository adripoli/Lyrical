//
//  NowPlayingStoreTests.swift
//  LyricalTests
//
//  The store is polled about once a second. The views, the lyrics and the
//  app's own sync all observe it, so a poll that only confirms what the
//  interpolated clock already said must not notify anyone.
//

import XCTest
@testable import Lyrical

/// Plays one track in real time from `start`, like Spotify would report it.
private final class PlayingSource: NowPlayingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var startUptime = ProcessInfo.processInfo.systemUptime
    private var startPosition: TimeInterval = 30

    let track = TrackInfo(id: "spotify:track:t", name: "Song", artist: "Artist", album: "Album",
                          duration: 200, artworkURL: nil, isAd: false)

    func jump(by seconds: TimeInterval) { lock.withLock { startPosition += seconds } }

    func availability() -> SpotifyAvailability { .running }
    func snapshot() async throws -> NowPlayingSnapshot {
        let position = lock.withLock { startPosition + ProcessInfo.processInfo.systemUptime - startUptime }
        return NowPlayingSnapshot(state: .playing, position: position, track: track)
    }
    func send(_ command: TransportCommand) async throws {}
}

@MainActor
final class NowPlayingStoreTests: XCTestCase {

    private var source: PlayingSource!
    private var store: NowPlayingStore!

    override func setUp() async throws {
        source = PlayingSource()
        let config = ConfigStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lyrical-store-\(UUID().uuidString).json"))
        store = NowPlayingStore(config: config, source: source, permissionCheck: { .granted })
        store.start()
        for _ in 0..<40 where store.snapshot.track == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(store.snapshot.track, "first poll never landed")
    }

    override func tearDown() async throws {
        store.stop()
    }

    /// Fires `changed` if anything a view or the app's sync reads changes.
    private func observe(_ changed: @escaping @Sendable () -> Void) {
        withObservationTracking {
            _ = store.snapshot
            _ = store.clock
        } onChange: { changed() }
    }

    func testAPollThatMatchesTheClockNotifiesNobody() async throws {
        let fired = expectation(description: "observers notified")
        fired.isInverted = true
        observe { fired.fulfill() }

        store.refreshNow()
        await fulfillment(of: [fired], timeout: 0.3)
    }

    func testAPollThatDisagreesReanchorsTheClock() async throws {
        let fired = expectation(description: "observers notified")
        observe { fired.fulfill() }

        source.jump(by: 0.5)
        store.refreshNow()
        await fulfillment(of: [fired], timeout: 1)
        try await Task.sleep(for: .milliseconds(50))
        let expected = try await source.snapshot().position
        XCTAssertEqual(store.displayPosition, expected, accuracy: 0.05)
    }
}
