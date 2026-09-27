//
//  TransportTests.swift
//  LyricalTests
//
//  The desktop control bar (ported from CoverWall) drives Spotify through
//  NowPlayingStore. Each button must reach Spotify and move the local clock
//  right away, or the bar and the lock-screen lyrics lag a poll behind.
//

import XCTest
@testable import Lyrical

private final class RecordingSource: NowPlayingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [TransportCommand] = []
    var sent: [TransportCommand] { lock.withLock { _sent } }

    let playing = NowPlayingSnapshot(
        state: .playing, position: 30,
        track: TrackInfo(id: "spotify:track:t", name: "Song", artist: "Artist", album: "Album",
                         duration: 200, artworkURL: nil, isAd: false))

    func availability() -> SpotifyAvailability { .running }
    func snapshot() async throws -> NowPlayingSnapshot { playing }
    func send(_ command: TransportCommand) async throws { lock.withLock { _sent.append(command) } }
}

@MainActor
final class TransportTests: XCTestCase {

    private var source: RecordingSource!
    private var store: NowPlayingStore!

    override func setUp() async throws {
        source = RecordingSource()
        let config = ConfigStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lyrical-transport-\(UUID().uuidString).json"))
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

    private func waitForSent(_ count: Int) async throws {
        for _ in 0..<40 where source.sent.count < count {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func testPlayPausePausesOptimistically() async throws {
        store.playPause()
        XCTAssertEqual(store.snapshot.state, .paused)
        XCTAssertFalse(store.clock.isPlaying)
        try await waitForSent(1)
        XCTAssertEqual(source.sent, [.playPause])
    }

    func testSkipRestartsTheClockAtZero() async throws {
        store.next()
        XCTAssertEqual(store.snapshot.position, 0)
        store.previous()
        try await waitForSent(2)
        XCTAssertEqual(Set(source.sent.map { "\($0)" }), ["next", "previous"])
    }

    func testSeekClampsToTheTrack() async throws {
        store.seek(to: 999)
        XCTAssertEqual(store.snapshot.position, 200)
        try await waitForSent(1)
        XCTAssertEqual(source.sent, [.seek(200)])
    }

    func testTimecode() {
        XCTAssertEqual(ControlBarView.timecode(0), "0:00")
        XCTAssertEqual(ControlBarView.timecode(65.9), "1:05")
        XCTAssertEqual(ControlBarView.timecode(3725), "1:02:05")
        XCTAssertEqual(ControlBarView.timecode(.nan), "0:00")
    }
}
