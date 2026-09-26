//
//  PollIntervalTests.swift
//  LyricalTests
//
//  A hand-edited `"pollIntervalPlaying": 0` must not become a tight loop of
//  Apple Events against Spotify.
//

import XCTest
@testable import Lyrical

final class PollIntervalTests: XCTestCase {
    func testZeroAndNegativeAreClampedToFourHertz() {
        XCTAssertEqual(NowPlayingStore.effectiveInterval(0), 0.25)
        XCTAssertEqual(NowPlayingStore.effectiveInterval(-3), 0.25)
    }

    func testSaneValuesPassThrough() {
        XCTAssertEqual(NowPlayingStore.effectiveInterval(1), 1)
        XCTAssertEqual(NowPlayingStore.effectiveInterval(5), 5)
    }

    func testNonFiniteFallsBackToOneSecond() {
        XCTAssertEqual(NowPlayingStore.effectiveInterval(.infinity), 1)
        XCTAssertEqual(NowPlayingStore.effectiveInterval(.nan), 1)
    }
}
