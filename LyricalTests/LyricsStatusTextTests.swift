//
//  LyricsStatusTextTests.swift
//  LyricalTests
//

import XCTest
@testable import Lyrical

final class LyricsStatusTextTests: XCTestCase {
    func testTitleCardLines() {
        XCTAssertNil(LyricsStatusText.titleCard(for: .idle))
        XCTAssertNil(LyricsStatusText.titleCard(for: .loaded(.synced([]))))
        XCTAssertEqual(LyricsStatusText.titleCard(for: .loading), "Loading lyrics…")
        XCTAssertEqual(LyricsStatusText.titleCard(for: .advertisement), "Advertisement")
        XCTAssertEqual(LyricsStatusText.titleCard(for: .loaded(.plain("x"))), "Plain lyrics only")
        XCTAssertEqual(LyricsStatusText.titleCard(for: .loaded(.instrumental)), "♪ Instrumental")
        XCTAssertEqual(LyricsStatusText.titleCard(for: .loaded(.notFound)), "No lyrics found")
        XCTAssertEqual(LyricsStatusText.titleCard(for: .loaded(.failed)), "Couldn't reach LRCLIB")
    }

    func testMenuLines() {
        XCTAssertEqual(LyricsStatusText.menu(for: .loaded(.synced([]))), "Synced lyrics · LRCLIB")
        XCTAssertEqual(LyricsStatusText.menu(for: .loading), "Loading…")
        XCTAssertEqual(LyricsStatusText.menu(for: .loaded(.instrumental)), "Instrumental")
    }
}
