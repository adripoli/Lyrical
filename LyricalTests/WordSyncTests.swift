//
//  WordSyncTests.swift
//  LyricalTests
//
//  All lyric text is invented.
//

import XCTest
@testable import Lyrical

final class WordSyncTests: XCTestCase {

    private func line(_ time: TimeInterval, _ text: String) -> LyricLine {
        LyricLine(time: time, text: text, isGap: text.isEmpty)
    }

    /// One segment per word, `step` apart, each running to the next.
    private func sung(_ words: [String], at start: TimeInterval, step: TimeInterval = 0.4) -> [TimedSegment] {
        words.enumerated().map { index, word in
            let time = start + step * Double(index)
            return TimedSegment(text: word + " ", start: time, end: time + step)
        }
    }

    // Our clock runs 2 s behind theirs throughout.
    private let ours = [
        (12.0, "Paper lanterns over the river"),
        (16.0, "Every one a question (nobody asked)"),
        (20.0, "Hold the light a little longer"),
        (24.0, "Folding up the evening"),
        (28.0, "Tell the wind we were already there"),
    ]

    private func theirs(skipping skipped: Set<Int> = []) -> [TimedSegment] {
        ours.enumerated().flatMap { index, entry -> [TimedSegment] in
            guard !skipped.contains(index) else { return [] }
            let words = entry.1.replacingOccurrences(of: "(nobody asked)", with: "")
                .split(separator: " ").map(String.init)
            return sung(words, at: entry.0 - 2)
        }
    }

    func testStampsLandOnOurClock() throws {
        let lines = ours.map { line($0.0, $0.1) }
        let timed = try XCTUnwrap(WordSync.attach(theirs(), to: lines))

        let words = try XCTUnwrap(timed[2].words)
        XCTAssertEqual(words.map(\.text).joined(), "Hold the light a little longer")
        for (index, word) in words.enumerated() {
            XCTAssertEqual(word.start, 20 + 0.4 * Double(index), accuracy: 0.001)
        }
    }

    func testGluedAndSplitWordsStillMatch() throws {
        var segments = theirs(skipping: [0])
        segments += [
            TimedSegment(text: "Paperlanterns ", start: 10.0, end: 10.8),
            TimedSegment(text: "o", start: 10.8, end: 11.1),
            TimedSegment(text: "ver ", start: 11.1, end: 11.4),
            TimedSegment(text: "the ", start: 11.4, end: 11.8),
            TimedSegment(text: "river", start: 11.8, end: 12.6),
        ]
        let lines = ours.map { line($0.0, $0.1) }
        let words = try XCTUnwrap(WordSync.attach(segments.sorted { $0.start < $1.start }, to: lines)?[0].words)

        XCTAssertEqual(words.map(\.text), ["Paper ", "lanterns ", "over ", "the ", "river"])
        XCTAssertEqual(words[0].start, 12.0, accuracy: 0.001)
        // "lanterns" starts at its sixth letter of the glued segment.
        XCTAssertEqual(words[1].start, 12.0 + 0.8 * 5 / 13, accuracy: 0.001)
        XCTAssertEqual(words[2].start, 12.8, accuracy: 0.001)
        XCTAssertEqual(words[4].end, 14.6, accuracy: 0.001)
    }

    func testBackingVocalsTheyLackDontSpoilTheLine() throws {
        let lines = ours.map { line($0.0, $0.1) }
        let words = try XCTUnwrap(WordSync.attach(theirs(), to: lines)?[1].words)

        XCTAssertEqual(words.map(\.text).joined(), "Every one a question (nobody asked)")
        XCTAssertEqual(words[3].start, 17.2, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(words[4].start, words[3].end)
        XCTAssertLessThan(words[5].end, 20)
    }

    func testARepeatedLineTakesTheRepeatSungAtThatTime() throws {
        // Ours sings the chorus twice; theirs only has the second one.
        let lines = [
            line(4, "Radio hiss on the northbound line"),
            line(10, "Static static tune me in"),
            line(30, "Static static tune me in"),
            line(40, "Counting the towns by the lights"),
        ]
        let segments = sung(["Radio", "hiss", "on", "the", "northbound", "line"], at: 2)
            + sung(["Static", "static", "tune", "me", "in"], at: 28)
            + sung(["Counting", "the", "towns", "by", "the", "lights"], at: 38)

        let timed = try XCTUnwrap(WordSync.attach(segments, to: lines))
        XCTAssertNil(timed[1].words)
        XCTAssertEqual(try XCTUnwrap(timed[2].words).first!.start, 30, accuracy: 0.001)
    }

    func testAnotherSongIsNotMatched() {
        let lines = ours.map { line($0.0, $0.1) }
        let segments = sung(["completely", "different", "words", "sung", "here"], at: 10)
        XCTAssertNil(WordSync.attach(segments, to: lines))
    }

    func testLinesWithRealStampsAreLeftAlone() throws {
        var lines = ours.map { line($0.0, $0.1) }
        let own = [LyricWord(text: "Paper lanterns over the river", start: 12, end: 14)]
        lines[0].words = own
        let timed = try XCTUnwrap(WordSync.attach(theirs(), to: lines))
        XCTAssertEqual(timed[0].words, own)
    }

    func testLettersIgnoreCaseAccentsAndPunctuation() {
        XCTAssertEqual(WordSync.letters("Café, NO! 2"), ["c", "a", "f", "e", "n", "o", "2"])
    }

    func testUnstampedWordsAreSpreadAroundTheStampedOnes() {
        let words = WordSync.timedWords(["one", "two", "three", "four", "five"],
                                        starts: [1: 11, 2: 12], ends: [2: 12.5],
                                        lineStart: 10, nextLine: 16)
        XCTAssertEqual(words.map(\.start)[0...2], [10, 11, 12])
        XCTAssertEqual(words[3].start, 12.5, accuracy: 0.001)   // estimated from the end of "three"
        XCTAssertGreaterThan(words[4].start, words[3].start)
        XCTAssertLessThanOrEqual(words[4].end, 16)
        XCTAssertEqual(words.map(\.text).joined(), "one two three four five")
    }

    func testAlignmentPairsOnlyEqualLetters() {
        let pairs = WordSync.align(Array("abcd"), Array("xabyd"))
        XCTAssertEqual(pairs, [1, 2, nil, 4])
    }

    func testAlignmentHonoursWhatsAllowed() {
        let pairs = WordSync.align(Array("ab"), Array("abab")) { _, j in j >= 2 }
        XCTAssertEqual(pairs, [2, 3])
    }
}
