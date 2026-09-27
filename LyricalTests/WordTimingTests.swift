//
//  WordTimingTests.swift
//  LyricalTests
//

import XCTest
@testable import Lyrical

final class WordTimingTests: XCTestCase {

    func testSyllableCounts() {
        XCTAssertEqual(WordTiming.syllables(in: "love"), 1)
        XCTAssertEqual(WordTiming.syllables(in: "tonight"), 2)
        XCTAssertEqual(WordTiming.syllables(in: "beautiful"), 3)
        XCTAssertEqual(WordTiming.syllables(in: "little"), 2)
        XCTAssertEqual(WordTiming.syllables(in: "hmm"), 1)
        XCTAssertEqual(WordTiming.syllables(in: "..."), 1)
        XCTAssertEqual(WordTiming.syllables(in: "東京"), 2)
    }

    func testEstimatedWordsRebuildTheLine() {
        let words = WordTiming.estimate("I  wanna dance, with somebody", start: 10, nextLine: 14)
        XCTAssertEqual(words.map(\.text).joined(), "I wanna dance, with somebody")
    }

    func testEstimatedWordsAreInOrderAndStartOnTheLine() {
        let words = WordTiming.estimate("I wanna dance with somebody", start: 10, nextLine: 14)
        XCTAssertEqual(words.first?.start, 10)
        for (a, b) in zip(words, words.dropFirst()) {
            XCTAssertLessThan(a.start, a.end)
            XCTAssertLessThanOrEqual(a.end, b.start)
        }
    }

    func testLongerWordsGetMoreTime() {
        let words = WordTiming.estimate("I celebrate", start: 0, nextLine: 5)
        XCTAssertGreaterThan(words[1].end - words[1].start, words[0].end - words[0].start)
    }

    func testSingingEndsBeforeTheNextLine() {
        let words = WordTiming.estimate("one two three four five six seven eight", start: 0, nextLine: 2)
        XCTAssertLessThan(words.last!.end, 2)
    }

    func testLongWaitIsNotFilledCompletely() {
        // Two words then 20 s of instrumental: they don't crawl across it,
        // and the held last note stops well short of the break.
        let words = WordTiming.estimate("oh yeah", start: 0, nextLine: 20)
        XCTAssertLessThan(words[1].start, 3)
        XCTAssertLessThanOrEqual(words.last!.end, words[1].start + WordTiming.maxHold)
    }

    func testAShortWaitIsSungQuicker() {
        let rushed = WordTiming.estimate("I wanna dance with somebody", start: 0, nextLine: 2)
        let relaxed = WordTiming.estimate("I wanna dance with somebody", start: 0, nextLine: 5)
        XCTAssertLessThan(rushed.last!.start, relaxed.last!.start)
    }

    func testPunctuationTakesABreath() {
        let breath = WordTiming.estimate("wait, go now", start: 0, nextLine: 4)
        let straight = WordTiming.estimate("wait go now", start: 0, nextLine: 4)
        XCTAssertGreaterThan(breath[1].start, straight[1].start)
        XCTAssertGreaterThan(WordTiming.weight(of: "go.", at: 1, of: 4), WordTiming.weight(of: "go,", at: 1, of: 4))
    }

    func testSmallFunctionWordsAreQuick() {
        XCTAssertLessThan(WordTiming.weight(of: "the", at: 1, of: 4), WordTiming.weight(of: "sun", at: 1, of: 4))
    }

    func testWordsRunOnWithoutGaps() {
        let words = WordTiming.estimate("paper boats drift away", start: 3, nextLine: 7)
        for (a, b) in zip(words, words.dropFirst()) { XCTAssertEqual(a.end, b.start) }
    }

    func testARepeatedLineIsSungAtItsTightestPace() {
        // The same chorus line twice: once hurried, once before a long break.
        // The second time it's sung as fast as the first, then held.
        let lines = WordTiming.fill([
            LyricLine(time: 0, text: "Paper boats in the rain", isGap: false),
            LyricLine(time: 3, text: "something else", isGap: false),
            LyricLine(time: 20, text: "paper boats in the rain!", isGap: false),
            LyricLine(time: 40, text: "the end", isGap: false),
        ])
        let first = lines[0].words!, again = lines[2].words!
        XCTAssertEqual(first.last!.start - first[0].start, again.last!.start - again[0].start, accuracy: 0.001)
    }

    func testFillEstimatesPlainLinesAndSkipsGaps() {
        let lines = WordTiming.fill([
            LyricLine(time: 0, text: "", isGap: true),
            LyricLine(time: 5, text: "hello there", isGap: false),
            LyricLine(time: 8, text: "bye", isGap: false),
        ])
        XCTAssertNil(lines[0].words)
        XCTAssertEqual(lines[1].words?.count, 2)
        XCTAssertEqual(lines[2].words?.count, 1)
    }

    func testFillKeepsRealStampsAndClosesAnOpenLastWord() {
        let stamped = [LyricWord(text: "hel", start: 1, end: 1.2), LyricWord(text: "lo", start: 1.2, end: 1.2)]
        let lines = WordTiming.fill([
            LyricLine(time: 1, text: "hello", isGap: false, words: stamped),
            LyricLine(time: 1.5, text: "next", isGap: false),
        ])
        XCTAssertEqual(lines[0].words?.first, stamped[0])
        XCTAssertEqual(lines[0].words!.last!.end, 1.2 + 0.3 * WordTiming.holdShare, accuracy: 0.0001)
    }

    func testCachedLinesWithoutWordsStillDecode() throws {
        let json = #"{"time": 1, "text": "hi", "isGap": false}"#
        let line = try JSONDecoder().decode(LyricLine.self, from: Data(json.utf8))
        XCTAssertNil(line.words)
    }

    func testSpareTimeIsHeldOnTheLastWord() {
        let words = WordTiming.estimate("hold me", start: 0, nextLine: 10)
        XCTAssertGreaterThan(words[1].end - words[1].start, words[0].end - words[0].start)
        XCTAssertEqual(words[1].end - words[1].start, WordTiming.maxHold, accuracy: 0.0001)
    }

    func testTheLastLineStillEnds() {
        let words = WordTiming.estimate("goodnight now", start: 100, nextLine: nil)
        XCTAssertGreaterThan(words.last!.end, words.last!.start)
        XCTAssertLessThanOrEqual(words.last!.end - words.last!.start, WordTiming.maxHold)
    }
}

final class SungWordStyleTests: XCTestCase {

    private let word = LyricWord(text: "love", start: 10, end: 11)

    private func look(_ time: TimeInterval, _ variant: SungLineVariant = .pop,
                      word: LyricWord? = nil) -> WordLook {
        SungWordStyle.look(for: word ?? self.word, index: 0, at: time, variant: variant)
    }

    func testBeforeTheWordItIsDimAndStill() {
        let before = look(9)
        XCTAssertEqual(before.scale, 1)
        XCTAssertEqual(before.opacity, SungWordStyle.unsungOpacity)
        XCTAssertEqual(before.glow, 0)
    }

    func testWhileSungItIsBrightAndBigger() {
        let during = look(10.5)
        XCTAssertEqual(during.opacity, 1)
        XCTAssertGreaterThan(during.scale, 1)
        XCTAssertGreaterThan(during.lift, 0)
    }

    func testGrowthIsProportionalToSecondsHeld() {
        let long = LyricWord(text: "oh", start: 0, end: 4)
        let one = look(1, word: long).scale
        let two = look(2, word: long).scale
        XCTAssertEqual(two - one, SungWordStyle.growthPerSecond, accuracy: 0.001)
        XCTAssertEqual(look(1.5, word: long).scale - one, SungWordStyle.growthPerSecond / 2, accuracy: 0.001)
    }

    func testGrowthIsCapped() {
        let endless = LyricWord(text: "oh", start: 0, end: 60)
        XCTAssertEqual(look(50, word: endless).scale, 1 + SungWordStyle.popScale + SungWordStyle.maxGrowth,
                       accuracy: 0.001)
    }

    func testEveryVariantSettlesAfterTheWord() {
        for variant in SungLineVariant.allCases {
            XCTAssertEqual(look(12, variant), SungWordStyle.resting, "\(variant)")
        }
    }

    func testEveryVariantSwellsWhileSung() {
        for variant in SungLineVariant.allCases {
            XCTAssertGreaterThan(look(10.9, variant).scale, 1, "\(variant)")
        }
    }

    func testSpreadKeepsSwollenWordsApart() {
        // Middle word grew by 10pt: the one before moves left 5, after moves right 5.
        XCTAssertEqual(SungWordStyle.spread(extras: [0, 10, 0], centered: true), [-5, 0, 5])
        XCTAssertEqual(SungWordStyle.spread(extras: [0, 10, 0], centered: false), [0, 5, 10])
    }

    func testRippleHopsTheLetterUnderTheSweep() {
        XCTAssertGreaterThan(SungWordStyle.letterHop(sweep: 0.1, letter: 0, of: 5), 0)
        XCTAssertEqual(SungWordStyle.letterHop(sweep: 0.1, letter: 4, of: 5), 0)
    }
}

final class SungLineVariantTests: XCTestCase {

    private func line(_ text: String) -> LyricLine { LyricLine(time: 0, text: text, isGap: text.isEmpty) }

    func testNeighboursNeverShareAStyle() {
        let texts = (0..<200).map { "line number \($0)" }
        let variants = SungLineVariant.variants(for: texts.map(line))
        for (a, b) in zip(variants, variants.dropFirst()) { XCTAssertNotEqual(a, b) }
        XCTAssertEqual(Set(variants).count, SungLineVariant.allCases.count)
    }

    func testARepeatedLineUsuallyKeepsItsStyle() {
        let variants = SungLineVariant.variants(for: ["Hello there", "and so on", "", "Hello, there!"].map(line))
        XCTAssertEqual(variants[0], variants[3])
    }
}
