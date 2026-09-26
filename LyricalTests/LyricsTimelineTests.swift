//
//  LyricsTimelineTests.swift
//  LyricalTests
//

import XCTest
@testable import Lyrical

final class LyricsTimelineTests: XCTestCase {

    private let lines = [
        LyricLine(time: 10, text: "a", isGap: false),
        LyricLine(time: 14, text: "b", isGap: false),
        LyricLine(time: 20, text: "c", isGap: false),
    ]

    func testBeforeFirstLineIsNil() {
        XCTAssertNil(LyricsTimeline.activeIndex(in: lines, at: 9.9, offset: 0))
    }

    func testExactlyOnBoundaryIsThatLine() {
        XCTAssertEqual(LyricsTimeline.activeIndex(in: lines, at: 14, offset: 0), 1)
    }

    func testBetweenLines() {
        XCTAssertEqual(LyricsTimeline.activeIndex(in: lines, at: 17, offset: 0), 1)
    }

    func testAfterLastLineStaysOnLast() {
        XCTAssertEqual(LyricsTimeline.activeIndex(in: lines, at: 500, offset: 0), 2)
    }

    func testOffsetShowsLinesEarlier() {
        XCTAssertEqual(LyricsTimeline.activeIndex(in: lines, at: 13.8, offset: 0.25), 1)
        XCTAssertEqual(LyricsTimeline.activeIndex(in: lines, at: 13.8, offset: 0), 0)
    }

    func testEmptyLinesAreNil() {
        XCTAssertNil(LyricsTimeline.activeIndex(in: [], at: 5, offset: 0))
        XCTAssertNil(LyricsTimeline.nextBoundary(in: [], at: 5, offset: 0))
    }

    func testNextBoundaryIsPlaybackPositionOfNextLine() {
        XCTAssertEqual(LyricsTimeline.nextBoundary(in: lines, at: 0, offset: 0), 10)
        XCTAssertEqual(LyricsTimeline.nextBoundary(in: lines, at: 11, offset: 0), 14)
        XCTAssertEqual(LyricsTimeline.nextBoundary(in: lines, at: 11, offset: 0.25), 13.75)
    }

    func testNextBoundaryAfterLastLineIsNil() {
        XCTAssertNil(LyricsTimeline.nextBoundary(in: lines, at: 21, offset: 0))
    }

    func testIdenticalTimestampsPickTheLaterLine() {
        let duet = [LyricLine(time: 5, text: "x", isGap: false), LyricLine(time: 5, text: "y", isGap: false)]
        XCTAssertEqual(LyricsTimeline.activeIndex(in: duet, at: 5, offset: 0), 1)
    }

    func testLongIntroGetsLeadingGap() {
        let result = LyricsTimeline.withIntroGap(lines)
        XCTAssertEqual(result.first, LyricLine(time: 0, text: "", isGap: true))
        XCTAssertEqual(result.count, 4)
    }

    func testShortIntroGetsNoGap() {
        let early = [LyricLine(time: 3, text: "a", isGap: false)]
        XCTAssertEqual(LyricsTimeline.withIntroGap(early), early)
    }

    func testExistingLeadingGapIsNotDoubled() {
        let gapped = [LyricLine(time: 1, text: "", isGap: true), LyricLine(time: 9, text: "a", isGap: false)]
        XCTAssertEqual(LyricsTimeline.withIntroGap(gapped), gapped)
    }
}
