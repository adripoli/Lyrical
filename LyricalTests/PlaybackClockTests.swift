//
//  PlaybackClockTests.swift
//  LyricalTests
//
//  The clock is the one place a bug is immediately visible to the eye — a bar
//  that stutters, overruns the end, or snaps back on every poll.
//

import XCTest
@testable import Lyrical

final class PlaybackClockTests: XCTestCase {

    private func makeClock(position: TimeInterval = 30,
                           uptime: TimeInterval = 1_000,
                           isPlaying: Bool = true,
                           duration: TimeInterval = 213) -> PlaybackClock {
        var clock = PlaybackClock()
        clock.reanchor(position: position, uptime: uptime, isPlaying: isPlaying, duration: duration)
        return clock
    }

    func testAdvancesWhilePlaying() {
        let clock = makeClock()
        XCTAssertEqual(clock.position(at: 1_000), 30, accuracy: 0.0001)
        XCTAssertEqual(clock.position(at: 1_005.5), 35.5, accuracy: 0.0001)
    }

    func testFrozenWhilePaused() {
        let clock = makeClock(isPlaying: false)
        XCTAssertEqual(clock.position(at: 1_060), 30, accuracy: 0.0001)
    }

    func testClampsAtDuration() {
        let clock = makeClock(position: 210, duration: 213)
        XCTAssertEqual(clock.position(at: 1_100), 213, accuracy: 0.0001)
    }

    func testClampsAtZeroForZeroDuration() {
        let clock = makeClock(position: 0, duration: 0)
        XCTAssertEqual(clock.position(at: 1_050), 0, accuracy: 0.0001)
    }

    func testReanchorReportsNoSeekForSubThresholdDrift() {
        var clock = makeClock()
        // A second of real time passed; Spotify reports 1.2s — normal poll jitter.
        XCTAssertFalse(clock.reanchor(position: 31.2, uptime: 1_001, isPlaying: true, duration: 213))
        XCTAssertEqual(clock.anchorPosition, 31.2, accuracy: 0.0001)
    }

    func testReanchorReportsSeekForLargeJump() {
        var clock = makeClock()
        // User scrubbed in Spotify's own UI while we were between polls.
        XCTAssertTrue(clock.reanchor(position: 120, uptime: 1_001, isPlaying: true, duration: 213))
        XCTAssertEqual(clock.anchorPosition, 120, accuracy: 0.0001)
    }

    func testReanchorIsIdempotent() {
        var clock = makeClock()
        clock.reanchor(position: 90, uptime: 1_010, isPlaying: true, duration: 213)
        let after = clock

        XCTAssertFalse(clock.reanchor(position: 90, uptime: 1_010, isPlaying: true, duration: 213))
        XCTAssertEqual(clock, after)
    }

    /// A poll that lands where the clock already predicted changes nothing,
    /// so nobody observing the clock redraws for it.
    func testAgreesWithAReadingItPredicted() {
        let clock = makeClock()
        XCTAssertTrue(clock.agrees(position: 40.02, uptime: 1_010, isPlaying: true, duration: 213))
        XCTAssertFalse(clock.agrees(position: 40.2, uptime: 1_010, isPlaying: true, duration: 213))
    }

    func testDisagreesOnAnythingButThePlayhead() {
        let clock = makeClock()
        XCTAssertFalse(clock.agrees(position: 40, uptime: 1_010, isPlaying: false, duration: 213))
        XCTAssertFalse(clock.agrees(position: 40, uptime: 1_010, isPlaying: true, duration: 180))
    }

    func testFractionUsesAnchorOnly() {
        let clock = makeClock(position: 106.5, duration: 213)
        XCTAssertEqual(clock.fraction, 0.5, accuracy: 0.0001)

        let empty = PlaybackClock()
        XCTAssertEqual(empty.fraction, 0)
    }
}
