//
//  LyricsfileTests.swift
//  LyricalTests
//
//  All lyric text is invented.
//

import XCTest
@testable import Lyrical

final class LyricsfileTests: XCTestCase {

    /// The spec's layout: sequences indented under their key.
    private let indented = """
    version: '1.0'

    metadata:
      title: 'Small Hours'
      artist: 'Example Artist'

    lines:
      - text: 'Stay until the morning'
        start_ms: 4200
        end_ms: 6800
        words:
          - text: 'Stay '
            start_ms: 4200
            end_ms: 4800
          - text: 'until '
            start_ms: 4800
            end_ms: 5400
          - text: 'the '
            start_ms: 5400
            end_ms: 5750
          - text: 'morning'
            start_ms: 5750
            end_ms: 6800
      - text: ''
        start_ms: 7000
      - text: ''
        start_ms: 7500

    plain: |
      Stay until the morning
    """

    /// LRCLIB's own layout: sequences flush with their key, unquoted text,
    /// a word without an end, a line without words.
    private let flush = """
    version: '1.0'
    metadata:
      title: Paper Boats
      artist: The Nobodies
      instrumental: false
    lines:
    - text: Paper boats
      start_ms: 13420
      end_ms: 14810
      words:
      - text: 'Paper '
        start_ms: 13420
      - text: boats
        start_ms: 14000
        end_ms: 14810
    - text: "It's \\"quoted\\""  # a comment
      start_ms: 15000
    plain: |-
      Paper boats

      It's quoted
    """

    func testReadsWordsFromTheSpecLayout() throws {
        let lines = try XCTUnwrap(Lyricsfile.wordSyncedLines(from: indented))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "Stay until the morning")
        XCTAssertEqual(lines[0].time, 4.2, accuracy: 0.0001)
        XCTAssertEqual(lines[0].words?.map(\.text), ["Stay ", "until ", "the ", "morning"])
        XCTAssertEqual(lines[0].words![3].end, 6.8, accuracy: 0.0001)
        XCTAssertTrue(lines[1].isGap)
    }

    func testReadsLRCLIBsLayout() throws {
        let lines = try XCTUnwrap(Lyricsfile.wordSyncedLines(from: flush))
        XCTAssertEqual(lines[0].words, [LyricWord(text: "Paper ", start: 13.42, end: 14.0),
                                        LyricWord(text: "boats", start: 14.0, end: 14.81)])
        XCTAssertEqual(lines[1].text, #"It's "quoted""#)
        XCTAssertNil(lines[1].words)
    }

    func testNoWordsMeansNothingToAdd() {
        let lineOnly = """
        version: '1.0'
        metadata:
          title: Paper Boats
          artist: The Nobodies
        lines:
        - text: Paper boats
          start_ms: 13420
        """
        XCTAssertNil(Lyricsfile.wordSyncedLines(from: lineOnly))
    }

    func testUnsupportedYAMLFailsRatherThanGuesses() {
        XCTAssertNil(YAML.parse("lines: [1, 2]"))
        XCTAssertNil(YAML.parse("a: 1\na: 2"))
        XCTAssertNil(YAML.parse("a: 'unterminated"))
        XCTAssertNil(Lyricsfile.wordSyncedLines(from: indented.replacingOccurrences(of: "version: '1.0'", with: "version: '2.0'")))
    }

    func testQuotedScalars() {
        let yaml = YAML.parse("""
        a: 'it''s'
        b: "tab\\tand \\u00e9"
        'c d': plain text # comment
        """)
        XCTAssertEqual(yaml?.mapping?["a"]?.string, "it's")
        XCTAssertEqual(yaml?.mapping?["b"]?.string, "tab\tand é")
        XCTAssertEqual(yaml?.mapping?["c d"]?.string, "plain text")
    }

    // MARK: - LRCLIB

    func testLRCLIBPrefersTheWordSyncedLyricsfile() {
        let record = LRCLIBRecord(syncedLyrics: "[00:13.42]Paper boats", lyricsfile: flush, hasWordSync: true)
        guard case .synced(let lines) = LRCLIBClient.result(from: record) else { return XCTFail("not synced") }
        XCTAssertEqual(lines[0].words?.count, 2)
    }

    func testLRCLIBFallsBackToLRCWithoutWords() {
        let record = LRCLIBRecord(syncedLyrics: "[00:13.42]Paper boats", lyricsfile: flush, hasWordSync: false)
        XCTAssertEqual(LRCLIBClient.result(from: record), .synced(LRCParser.parse("[00:13.42]Paper boats")))
    }

    func testSearchPrefersWordSyncedRecords() {
        let records = [
            LRCLIBRecord(duration: 200, syncedLyrics: "[00:01.00]a"),
            LRCLIBRecord(duration: 201, syncedLyrics: "[00:01.00]b", hasWordSync: true),
        ]
        XCTAssertEqual(LRCLIBClient.bestMatch(records, duration: 200)?.hasWordSync, true)
    }
}
