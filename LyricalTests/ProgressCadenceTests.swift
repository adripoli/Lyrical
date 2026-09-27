//
//  ProgressCadenceTests.swift
//  LyricalTests
//
//  The control bar sits under Liquid Glass, so every progress redraw makes
//  WindowServer re-render the glass. It should redraw only when something
//  visibly moves: the fill by a device pixel, or the clock by a second.
//

import XCTest
@testable import Lyrical

final class ProgressCadenceTests: XCTestCase {

    func testATypicalSongRedrawsAboutOncePerPixel() {
        // 800 px of bar over 180 s is 4.4 px a second: 5 redraws a second
        // keeps each step under a pixel.
        XCTAssertEqual(ProgressCadence.interval(duration: 180, barWidth: 400, scale: 2), 0.2, accuracy: 1e-9)
    }

    func testAShortSongIsCappedAtTenHertz() {
        XCTAssertEqual(ProgressCadence.interval(duration: 30, barWidth: 400, scale: 2), 0.1, accuracy: 1e-9)
    }

    /// The elapsed-time label still has to change every second.
    func testALongEpisodeStillRedrawsEverySecond() {
        XCTAssertEqual(ProgressCadence.interval(duration: 3600, barWidth: 400, scale: 2), 1, accuracy: 1e-9)
    }

    func testUnknownDurationRedrawsEverySecond() {
        XCTAssertEqual(ProgressCadence.interval(duration: 0, barWidth: 400, scale: 2), 1, accuracy: 1e-9)
        XCTAssertEqual(ProgressCadence.interval(duration: .nan, barWidth: 400, scale: 2), 1, accuracy: 1e-9)
    }

    func testLowPowerModeRedrawsEverySecond() {
        XCTAssertEqual(ProgressCadence.interval(duration: 30, barWidth: 400, scale: 2, lowPower: true), 1, accuracy: 1e-9)
    }

    /// Every interval divides a second evenly, so ticks aligned to the
    /// playhead land on each whole second and the label never lags.
    func testIntervalsDivideASecond() {
        for duration in stride(from: 5.0, through: 4000, by: 7.3) {
            let interval = ProgressCadence.interval(duration: duration, barWidth: 400, scale: 2)
            let perSecond = 1 / interval
            XCTAssertEqual(perSecond, perSecond.rounded(), accuracy: 1e-9, "\(duration)")
        }
    }

    /// Ticks fall just after each multiple of the interval on the playhead,
    /// never in the future (a schedule starting later would draw late).
    func testScheduleStartIsAlignedToThePlayhead() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let start = ProgressCadence.scheduleStart(position: 12.3, interval: 0.25, now: now)
        XCTAssertLessThanOrEqual(start, now)
        // The next tick after `now` is at playhead 12.5 + the small lag.
        let next = start.addingTimeInterval(0.25)
        XCTAssertEqual(12.3 + next.timeIntervalSince(now), 12.5 + ProgressCadence.lag, accuracy: 1e-9)
    }

    func testScheduleStartRightOnATick() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let start = ProgressCadence.scheduleStart(position: 12.5, interval: 0.25, now: now)
        XCTAssertLessThanOrEqual(start, now)
        XCTAssertGreaterThan(start, now.addingTimeInterval(-0.25))
    }
}
