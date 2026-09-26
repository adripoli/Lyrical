//
//  NowPlayingStartupTests.swift
//  LyricalTests
//
//  Regression: AEDeterminePermissionToAutomateTarget can block indefinitely for
//  Spotify (observed on macOS 26 even with askUserIfNeeded = false). Called on
//  the main thread at launch, it froze Lyrical before its window reached the
//  screen, so nothing ever appeared. The silent check must never block start().
//

import XCTest
@testable import Lyrical

private final class IdleSource: NowPlayingSource, @unchecked Sendable {
    func availability() -> SpotifyAvailability { .running }
    func snapshot() async throws -> NowPlayingSnapshot { .idle }
    func send(_ command: TransportCommand) async throws {}
}

/// Never gets a reply out of "Spotify", so only the permission check can say anything.
private final class SilentSource: NowPlayingSource, @unchecked Sendable {
    func availability() -> SpotifyAvailability { .running }
    func snapshot() async throws -> NowPlayingSnapshot { throw SpotifyError.timedOut }
    func send(_ command: TransportCommand) async throws {}
}

@MainActor
final class NowPlayingStartupTests: XCTestCase {

    private func makeConfig() -> ConfigStore {
        ConfigStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lyrical-startup-\(UUID().uuidString).json"))
    }

    func testHangingPermissionCheckDoesNotBlockStart() {
        let store = NowPlayingStore(config: makeConfig(), source: IdleSource(),
                                    permissionCheck: { Thread.sleep(forTimeInterval: 3); return .granted },
                                    permissionTimeout: 0.2)
        defer { store.stop() }

        let started = Date()
        store.start()

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "start() must not wait on the permission check")
    }

    func testPermissionCheckResultStillArrives() async throws {
        let store = NowPlayingStore(config: makeConfig(), source: SilentSource(),
                                    permissionCheck: { .denied },
                                    permissionTimeout: 2)
        defer { store.stop() }

        store.start()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(store.permission, .denied)
    }
}
