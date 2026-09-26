//
//  LRCLIBClientTests.swift
//  LyricalTests
//
//  All lyric text is invented.
//

import XCTest
@testable import Lyrical

final class LRCLIBClientTests: XCTestCase {

    private let synced = "[00:01.00]first invented line\n[00:03.00]second invented line"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func client() -> LRCLIBClient {
        LRCLIBClient(session: StubURLProtocol.session(), userAgent: "Lyrical/test (https://example.invalid)")
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    // MARK: - /api/get

    func testGetSendsAllFieldsAndUserAgent() async {
        StubURLProtocol.handler = { _ in (200, self.json(["syncedLyrics": self.synced, "instrumental": false])) }

        _ = await client().lyrics(title: "Song", artist: "Artist", album: "Album", duration: 212.6)

        let request = StubURLProtocol.requests[0]
        XCTAssertEqual(request.url?.path, "/api/get")
        XCTAssertEqual(query(request), ["track_name": "Song", "artist_name": "Artist",
                                        "album_name": "Album", "duration": "213"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Lyrical/test (https://example.invalid)")
    }

    func testSpecialCharactersSurviveEncoding() async {
        StubURLProtocol.handler = { _ in (200, self.json(["syncedLyrics": self.synced])) }

        _ = await client().lyrics(title: "Rock & Roll + Me = #1?", artist: "Beyoncé 東京", album: "A/B", duration: 100)

        let request = StubURLProtocol.requests[0]
        let raw = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        XCTAssertTrue(raw.contains("%2B"), "a bare + would be read as a space: \(raw)")
        XCTAssertFalse(raw.contains("+"))
        XCTAssertEqual(query(request)["track_name"], "Rock & Roll + Me = #1?")
        XCTAssertEqual(query(request)["artist_name"], "Beyoncé 東京")
    }

    func testSyncedRecordBecomesSynced() async {
        StubURLProtocol.handler = { _ in (200, self.json(["syncedLyrics": self.synced, "plainLyrics": "x"])) }

        let result = await client().lyrics(title: "Song", artist: "A", album: "B", duration: 100)

        XCTAssertEqual(result, .synced(LRCParser.parse(synced)))
    }

    func testInstrumentalFlagWins() async {
        StubURLProtocol.handler = { _ in (200, self.json(["instrumental": true])) }
        let result = await client().lyrics(title: "Song", artist: "A", album: "B", duration: 100)
        XCTAssertEqual(result, .instrumental)
    }

    func testPlainOnlyBecomesPlain() async {
        StubURLProtocol.handler = { _ in (200, self.json(["plainLyrics": "  invented words  \n"])) }
        let result = await client().lyrics(title: "Song", artist: "A", album: "B", duration: 100)
        XCTAssertEqual(result, .plain("invented words"))
    }

    func testSyncedWithOnlyGapsFallsBackToPlain() {
        let record = LRCLIBRecord(plainLyrics: "invented words", syncedLyrics: "[00:01.00]\n[00:02.00]")
        XCTAssertEqual(LRCLIBClient.result(from: record), .plain("invented words"))
    }

    // MARK: - Search fallback

    func test404FallsBackToSearchWithNormalizedTitle() async {
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/get" { return (404, self.json(["code": 404])) }
            return (200, self.json([["duration": 200, "syncedLyrics": self.synced]]))
        }

        let result = await client().lyrics(title: "Song - 2011 Remaster", artist: "Artist", album: "B", duration: 200)

        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/api/get", "/api/search"])
        XCTAssertEqual(query(StubURLProtocol.requests[1]), ["track_name": "Song", "artist_name": "Artist"])
        XCTAssertEqual(result, .synced(LRCParser.parse(synced)))
    }

    func testSearchPrefersSyncedThenClosestDurationWithinTolerance() {
        let records = [
            LRCLIBRecord(duration: 190, syncedLyrics: "[00:01.00]too far"),
            LRCLIBRecord(duration: 199.5, plainLyrics: "closest but plain"),
            LRCLIBRecord(duration: 202, syncedLyrics: "[00:01.00]synced but further"),
            LRCLIBRecord(duration: 201, syncedLyrics: "[00:01.00]synced and closer"),
        ]
        XCTAssertEqual(LRCLIBClient.bestMatch(records, duration: 200)?.syncedLyrics, "[00:01.00]synced and closer")
    }

    func testSearchWithNothingInToleranceIsNotFound() async {
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/get" { return (404, Data()) }
            return (200, self.json([["duration": 300, "syncedLyrics": self.synced]]))
        }
        let result = await client().lyrics(title: "Song", artist: "A", album: "B", duration: 200)
        XCTAssertEqual(result, .notFound)
    }

    func testUnknownDurationSkipsGetAndSearches() async {
        StubURLProtocol.handler = { _ in (200, self.json([["duration": 999, "syncedLyrics": self.synced]])) }
        let result = await client().lyrics(title: "Song", artist: "A", album: "B", duration: 0)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/api/search"])
        XCTAssertEqual(result, .synced(LRCParser.parse(synced)))
    }

    // MARK: - Failures

    func testServerErrorIsFailed() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let result = await client().lyrics(title: "Song", artist: "A", album: "B", duration: 100)
        XCTAssertEqual(result, .failed)
    }

    func testTransportErrorIsFailed() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let result = await client().lyrics(title: "Song", artist: "A", album: "B", duration: 100)
        XCTAssertEqual(result, .failed)
    }

    func testGarbageBodyIsFailed() async {
        StubURLProtocol.handler = { _ in (200, Data("<html>".utf8)) }
        let result = await client().lyrics(title: "Song", artist: "A", album: "B", duration: 100)
        XCTAssertEqual(result, .failed)
    }
}
