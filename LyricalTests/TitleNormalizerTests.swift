//
//  TitleNormalizerTests.swift
//  LyricalTests
//

import XCTest
@testable import Lyrical

final class TitleNormalizerTests: XCTestCase {
    func testStripsRemasterSuffix() {
        XCTAssertEqual(TitleNormalizer.normalize("Song Title - 2011 Remaster"), "Song Title")
        XCTAssertEqual(TitleNormalizer.normalize("Song Title - Remastered"), "Song Title")
    }

    func testStripsLiveAndEditSuffixes() {
        XCTAssertEqual(TitleNormalizer.normalize("Song - Live at Some Arena"), "Song")
        XCTAssertEqual(TitleNormalizer.normalize("Song - Radio Edit"), "Song")
        XCTAssertEqual(TitleNormalizer.normalize(#"Song - From "Some Film""#), "Song")
    }

    func testStripsFeatureCredits() {
        XCTAssertEqual(TitleNormalizer.normalize("Song (feat. Someone Else)"), "Song")
        XCTAssertEqual(TitleNormalizer.normalize("Song (ft. Someone)"), "Song")
        XCTAssertEqual(TitleNormalizer.normalize("Song (with Other Person)"), "Song")
        XCTAssertEqual(TitleNormalizer.normalize("Song [feat. Someone]"), "Song")
    }

    func testStripsBracketedTags() {
        XCTAssertEqual(TitleNormalizer.normalize("Song [Explicit]"), "Song")
    }

    func testLeavesMeaningfulParenthesesAndDashesAlone() {
        XCTAssertEqual(TitleNormalizer.normalize("Song (Interlude)"), "Song (Interlude)")
        XCTAssertEqual(TitleNormalizer.normalize("Left - Right"), "Left - Right")
    }

    func testCollapsesWhitespace() {
        XCTAssertEqual(TitleNormalizer.normalize("  Spaced   Out  "), "Spaced Out")
    }
}
