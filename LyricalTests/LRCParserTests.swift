//
//  LRCParserTests.swift
//  LyricalTests
//

import XCTest
@testable import Lyrical

final class LRCParserTests: XCTestCase {

    func testParsesAllTimestampPrecisions() {
        let lines = LRCParser.parse("[00:01]one\n[00:02.5]two\n[00:03.25]three\n[01:04.125]four")
        XCTAssertEqual(lines.map(\.time), [1, 2.5, 3.25, 64.125])
        XCTAssertEqual(lines.map(\.text), ["one", "two", "three", "four"])
    }

    func testMultipleTimestampsOnOneLineRepeatTheText() {
        let lines = LRCParser.parse("[00:10.00][00:30.00]chorus\n[00:20.00]verse")
        XCTAssertEqual(lines.map(\.time), [10, 20, 30])
        XCTAssertEqual(lines.map(\.text), ["chorus", "verse", "chorus"])
    }

    func testPositiveOffsetShowsLinesEarlier() {
        let lines = LRCParser.parse("[offset:+500]\n[00:10.00]a")
        XCTAssertEqual(lines.first?.time ?? -1, 9.5, accuracy: 0.0001)
    }

    func testNegativeOffsetAppliesEvenWhenTagComesLast() {
        let lines = LRCParser.parse("[00:10.00]a\n[offset:-250]")
        XCTAssertEqual(lines.first?.time ?? -1, 10.25, accuracy: 0.0001)
    }

    func testOffsetNeverPushesBelowZero() {
        let lines = LRCParser.parse("[offset:+5000]\n[00:01.00]a")
        XCTAssertEqual(lines.first?.time, 0)
    }

    func testMetadataTagsAreIgnored() {
        let text = "[ar:Someone]\n[ti:Song]\n[al:Album]\n[by:me]\n[length:03:20]\n[re:tool]\n[ve:1.0]\n[00:01.00]a"
        XCTAssertEqual(LRCParser.parse(text).map(\.text), ["a"])
    }

    func testOnlyMetadataYieldsNoLines() {
        XCTAssertEqual(LRCParser.parse("[ar:x]\n[ti:y]"), [])
    }

    func testEmptyTextBecomesGap() {
        let lines = LRCParser.parse("[00:01.00]a\n[00:05.00]\n[00:09.00]b")
        XCTAssertEqual(lines.map(\.isGap), [false, true, false])
        XCTAssertEqual(lines[1].text, "")
    }

    func testConsecutiveGapsCollapse() {
        let lines = LRCParser.parse("[00:01.00]a\n[00:05.00]\n[00:06.00]   \n[00:09.00]b")
        XCTAssertEqual(lines.map(\.time), [1, 5, 9])
    }

    func testCRLFAndBareCRLineEndings() {
        XCTAssertEqual(LRCParser.parse("[00:01.00]a\r\n[00:02.00]b\r[00:03.00]c").map(\.text), ["a", "b", "c"])
    }

    func testMalformedLinesAreSkipped() {
        let lines = LRCParser.parse("garbage\n[xx:yy]nope\n[00:1a]bad\n[00:01.00]ok\n\n")
        XCTAssertEqual(lines.map(\.text), ["ok"])
    }

    func testUnsortedInputIsSortedStably() {
        let lines = LRCParser.parse("[00:05.00]b\n[00:01.00]a\n[00:05.00]c")
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c"])
    }

    func testExactDuplicatesAreDropped() {
        XCTAssertEqual(LRCParser.parse("[00:01.00]a\n[00:01.00]a").count, 1)
    }

    func testEnhancedWordTimestampsAreStripped() {
        let lines = LRCParser.parse("[00:01.00]<00:01.00>hello <00:01.50>world")
        XCTAssertEqual(lines.first?.text, "hello world")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(LRCParser.parse("  [00:01.00]   spaced out   ").first?.text, "spaced out")
    }
}
