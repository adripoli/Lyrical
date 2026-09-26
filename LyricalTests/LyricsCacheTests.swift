//
//  LyricsCacheTests.swift
//  LyricalTests
//

import XCTest
@testable import Lyrical

final class LyricsCacheTests: XCTestCase {

    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000_000)
    }

    private var directory: URL!
    private var clock: Clock!
    private var cache: LyricsCache!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lyrical-lyrics-tests-\(UUID().uuidString)")
        clock = Clock()
        let clock = self.clock!
        cache = LyricsCache(directory: directory, now: { clock.date })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private let synced = LyricsResult.synced([LyricLine(time: 1, text: "invented", isGap: false)])

    func testStableHashKnownValues() {
        XCTAssertEqual(StableHash.fnv1a(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableHash.fnv1a("a"), 0xaf63_dc4c_8601_ec8c)
    }

    func testRoundTripsEveryCacheableResult() async {
        let cases: [(String, LyricsResult)] = [
            ("t1", synced), ("t2", .plain("words")), ("t3", .instrumental), ("t4", .notFound),
        ]
        for (id, result) in cases {
            await cache.store(result, for: id)
            let read = await cache.result(for: id)
            XCTAssertEqual(read, result)
        }
    }

    func testMissIsNil() async {
        let read = await cache.result(for: "never-stored")
        XCTAssertNil(read)
    }

    func testFailedIsNeverStored() async {
        await cache.store(.failed, for: "t")
        let read = await cache.result(for: "t")
        XCTAssertNil(read)
    }

    func testNotFoundExpiresAfterSevenDays() async {
        await cache.store(.notFound, for: "t")

        clock.date += 6 * 24 * 3600
        let sixDays = await cache.result(for: "t")
        XCTAssertEqual(sixDays, .notFound)

        clock.date += 2 * 24 * 3600
        let eightDays = await cache.result(for: "t")
        XCTAssertNil(eightDays)
    }

    func testPositiveResultsNeverExpire() async {
        await cache.store(synced, for: "t")
        clock.date += 365 * 24 * 3600
        let read = await cache.result(for: "t")
        XCTAssertEqual(read, synced)
    }

    func testCorruptFileIsAMissAndIsDeleted() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(LyricsCache.fileName(for: "t"))
        try Data("{ not json".utf8).write(to: url)

        let read = await cache.result(for: "t")
        XCTAssertNil(read)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemove() async {
        await cache.store(synced, for: "t")
        await cache.remove(trackID: "t")
        let read = await cache.result(for: "t")
        XCTAssertNil(read)
    }

    func testFileNamesAreSafeShortStableAndDistinct() {
        let local = "spotify:local:Some+Artist:Some+Album:" + String(repeating: "Very+Long+Title+", count: 40) + ":245"
        for id in ["spotify:track:abc", "../../etc/passwd", "a/b", local] {
            let name = LyricsCache.fileName(for: id)
            XCTAssertFalse(name.contains("/"), name)
            XCTAssertFalse(name.contains(".."), name)
            XCTAssertLessThanOrEqual(name.utf8.count, 100, name)
            XCTAssertTrue(name.hasSuffix(".json"))
            XCTAssertEqual(name, LyricsCache.fileName(for: id))
        }
        XCTAssertNotEqual(LyricsCache.fileName(for: "a:b"), LyricsCache.fileName(for: "a/b"))
    }
}
