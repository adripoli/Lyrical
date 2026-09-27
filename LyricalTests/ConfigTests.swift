//
//  ConfigTests.swift
//  LyricalTests
//
//  A config file the user hand-edits is untrusted input: partial, stale or
//  outright broken must all still launch.
//

import XCTest
@testable import Lyrical

@MainActor
final class ConfigTests: XCTestCase {

    private func decode(_ json: String) throws -> LyricalConfig {
        try JSONDecoder().decode(LyricalConfig.self, from: Data(json.utf8))
    }

    func testFullJSONDecodes() throws {
        let config = try decode("""
        {
          "displays": "main",
          "showWallpaper": false,
          "showOnLockScreen": false,
          "startAtLogin": false,
          "pollIntervalPlaying": 2.5,
          "pollIntervalPaused": 30,
          "crossfadeDuration": 1.25,
          "lyricsOffset": -0.5,
          "fontSizeFraction": 0.06,
          "fontDesign": "serif",
          "textAlignment": "leading",
          "columnWidthFraction": 0.8,
          "anchorYFraction": 0.3,
          "blurInactive": false,
          "animateWords": false,
          "lookUpWordTiming": false,
          "backdropBlurRadius": 25,
          "backdropDim": 0.5,
          "coverHeightFraction": 0.4
        }
        """)

        XCTAssertEqual(config.displays, .main)
        XCTAssertFalse(config.showWallpaper)
        XCTAssertFalse(config.showOnLockScreen)
        XCTAssertFalse(config.startAtLogin)
        XCTAssertEqual(config.pollIntervalPlaying, 2.5)
        XCTAssertEqual(config.pollIntervalPaused, 30)
        XCTAssertEqual(config.crossfadeDuration, 1.25)
        XCTAssertEqual(config.lyricsOffset, -0.5)
        XCTAssertEqual(config.fontSizeFraction, 0.06)
        XCTAssertEqual(config.fontDesign, .serif)
        XCTAssertEqual(config.textAlignment, .leading)
        XCTAssertEqual(config.columnWidthFraction, 0.8)
        XCTAssertEqual(config.anchorYFraction, 0.3)
        XCTAssertFalse(config.blurInactive)
        XCTAssertFalse(config.animateWords)
        XCTAssertFalse(config.lookUpWordTiming)
        XCTAssertEqual(config.backdropBlurRadius, 25)
        XCTAssertEqual(config.backdropDim, 0.5)
        XCTAssertEqual(config.coverHeightFraction, 0.4)
    }

    func testDefaultFontDesignDecodesFromTheWordDefault() throws {
        XCTAssertEqual(try decode(#"{ "fontDesign": "default" }"#).fontDesign, .standard)
    }

    func testEmptyObjectYieldsAllDefaults() throws {
        XCTAssertEqual(try decode("{}"), LyricalConfig())
    }

    func testPartialJSONDefaultsOnlyMissingKeys() throws {
        let config = try decode(#"{ "lyricsOffset": 1.0, "displays": "main" }"#)
        let defaults = LyricalConfig()

        XCTAssertEqual(config.lyricsOffset, 1.0)
        XCTAssertEqual(config.displays, .main)
        XCTAssertEqual(config.fontSizeFraction, defaults.fontSizeFraction)
        XCTAssertEqual(config.textAlignment, defaults.textAlignment)
    }

    func testUnknownKeysAreIgnored() throws {
        let config = try decode(#"{ "somethingFromTheFuture": 7, "nested": { "a": 1 }, "anchorYFraction": 0.5 }"#)
        XCTAssertEqual(config.anchorYFraction, 0.5)
    }

    func testBundledDefaultsMatchCodeDefaults() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "config.default", withExtension: "json"),
                                "config.default.json should ship inside the host app bundle")
        let config = try JSONDecoder().decode(LyricalConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(config, LyricalConfig())
    }

    // MARK: - Store

    func testStoreLoadsWrittenFile() throws {
        let url = try makeTempConfigURL()
        try #"{ "fontSizeFraction": 0.07 }"#.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(url: url)
        store.load()

        XCTAssertEqual(store.current.fontSizeFraction, 0.07)
    }

    func testStoreFallsBackToDefaultsOnMalformedJSON() throws {
        let url = try makeTempConfigURL()
        try "{ this is not json at all ".write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(url: url)
        store.load()

        XCTAssertEqual(store.current, LyricalConfig())
    }

    func testStoreSeedsMissingFile() throws {
        let url = try makeTempConfigURL()
        try? FileManager.default.removeItem(at: url)

        let store = ConfigStore(url: url)
        store.load()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.current, LyricalConfig())
    }

    func testUpdatePersistsToDisk() throws {
        let url = try makeTempConfigURL()
        let store = ConfigStore(url: url)
        store.load()

        store.update { $0.lyricsOffset = 0.75 }

        let reread = ConfigStore(url: url)
        reread.load()
        XCTAssertEqual(reread.current.lyricsOffset, 0.75)
    }

    private func makeTempConfigURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lyrical-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("config.json")
    }
}
