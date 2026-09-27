//
//  NetEaseClientTests.swift
//  LyricalTests
//
//  All lyric text is invented.
//

import XCTest
@testable import Lyrical

final class NetEaseClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private let yrc = """
    {"t":0,"c":[{"tx":"Lyrics by: "},{"tx":"Nobody"}]}
    [1000,1000](1000,500,0)Paper (1500,500,0)boats
    [4000,800](4000,400,0)drift(4400,400,0)ing
    """

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func song(_ id: Int, _ name: String, _ artist: String, _ seconds: Double?) -> [String: Any] {
        var song: [String: Any] = ["id": id, "name": name, "artists": [["name": artist]]]
        if let seconds { song["duration"] = seconds * 1000 }
        return song
    }

    private func client() -> NetEaseClient { NetEaseClient(session: StubURLProtocol.session()) }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testParsesYRCSkippingCredits() {
        XCTAssertEqual(NetEaseClient.parseYRC(yrc), [
            TimedSegment(text: "Paper ", start: 1.0, end: 1.5),
            TimedSegment(text: "boats", start: 1.5, end: 2.0),
            TimedSegment(text: "drift", start: 4.0, end: 4.4),
            TimedSegment(text: "ing", start: 4.4, end: 4.8),
        ])
        XCTAssertEqual(NetEaseClient.parseYRC("[00:01.00]plain lrc line"), [])
    }

    func testCandidatesMatchTitleArtistAndDuration() throws {
        let data = json(["result": ["songs": [
            song(1, "Paper Boats (Remastered)", "The Nobodies", 200.5),
            song(2, "Paper Boats", "The Nobodies", 180),
            song(3, "Paper Boats", "Someone Else", 201),
            song(4, "Paper Boats", "The Nobodies", 201),
        ]]])
        let songs = try JSONDecoder().decode(NetEaseClient.SearchResponse.self, from: data).result!.songs!
        let picked = NetEaseClient.candidates(songs, title: "Paper Boats - 2011 Remaster",
                                              artist: "The Nobodies, Guest", duration: 201)
        XCTAssertEqual(picked.map(\.id), [4, 1])
    }

    func testATitlePrefixNeedsDurationsToVouchForIt() throws {
        let data = json(["result": ["songs": [song(1, "Paper Boats (Live)", "The Nobodies", nil)]]])
        let songs = try JSONDecoder().decode(NetEaseClient.SearchResponse.self, from: data).result!.songs!
        XCTAssertTrue(NetEaseClient.candidates(songs, title: "Paper Boats", artist: "The Nobodies", duration: 201).isEmpty)
    }

    func testFoundSearchesThenFetchesWordTiming() async {
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/search/get") {
                return (200, self.json(["result": ["songs": [self.song(7, "Paper Boats", "The Nobodies", 201)]]]))
            }
            return (200, self.json(["yrc": ["lyric": self.yrc]]))
        }

        let lookup = await client().wordTiming(title: "Paper Boats", artist: "The Nobodies", duration: 200)

        XCTAssertEqual(lookup, .found(NetEaseClient.parseYRC(yrc)))
        XCTAssertEqual(query(StubURLProtocol.requests[0])["s"], "Paper Boats The Nobodies")
        XCTAssertEqual(StubURLProtocol.requests[1].url?.path, "/api/song/lyric/v1")
        XCTAssertEqual(query(StubURLProtocol.requests[1])["id"], "7")
    }

    func testNoMatchOrNoWordTimingIsNone() async {
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/search/get") {
                return (200, self.json(["result": ["songs": [self.song(7, "Paper Boats", "The Nobodies", 201)]]]))
            }
            return (200, self.json(["lrc": ["lyric": "[00:01.00]line only"]]))
        }
        let noWords = await client().wordTiming(title: "Paper Boats", artist: "The Nobodies", duration: 200)
        XCTAssertEqual(noWords, WordTimingLookup.none)

        StubURLProtocol.handler = { _ in (200, self.json(["result": [:]])) }
        let noSong = await client().wordTiming(title: "Paper Boats", artist: "The Nobodies", duration: 200)
        XCTAssertEqual(noSong, WordTimingLookup.none)
    }

    func testTheSessionNeverKeepsCookies() {
        // With the cookie from its first answer, NetEase's search returns
        // unrelated songs, so the client must never send one back.
        let configuration = NetEaseClient.makeSession().configuration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
    }

    func testServerTroubleIsFailed() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        let lookup = await client().wordTiming(title: "Paper Boats", artist: "The Nobodies", duration: 200)
        XCTAssertEqual(lookup, .failed)
    }
}

final class CachedLyricsProviderWordTimingTests: XCTestCase {

    private var directory: URL!
    private var cache: LyricsCache!

    private let lines = [
        LyricLine(time: 10, text: "Paper boats", isGap: false),
        LyricLine(time: 14, text: "drifting away", isGap: false),
    ]
    private let track = TrackInfo(id: "spotify:track:invented", name: "Paper Boats", artist: "The Nobodies",
                                  album: "Invented", duration: 200, artworkURL: nil, isAd: false)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lyrical-word-timing-tests-\(UUID().uuidString)")
        cache = LyricsCache(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func provider(enabled: Bool = true) -> CachedLyricsProvider {
        CachedLyricsProvider(client: LRCLIBClient(session: StubURLProtocol.session(), userAgent: "test"),
                             cache: cache, wordTiming: NetEaseClient(session: StubURLProtocol.session()),
                             isWordTimingEnabled: { enabled })
    }

    private func answer(status: Int = 200) {
        let yrc = "[9000,1000](9000,400,0)Paper (9400,600,0)boats\n[13000,1000](13000,500,0)drifting (13500,500,0)away"
        StubURLProtocol.handler = { request in
            guard status == 200 else { return (status, Data()) }
            if request.url!.path.hasSuffix("/search/get") {
                let songs = [["id": 1, "name": "Paper Boats", "artists": [["name": "The Nobodies"]], "duration": 200_000]]
                return (200, try JSONSerialization.data(withJSONObject: ["result": ["songs": songs]]))
            }
            return (200, try JSONSerialization.data(withJSONObject: ["yrc": ["lyric": yrc]]))
        }
    }

    func testFoundWordsAreReturnedAndRemembered() async throws {
        answer()
        let timed = await provider().wordTimed(lines, for: track)

        let words = try XCTUnwrap(timed?[0].words)
        XCTAssertEqual(words.map(\.start), [10, 10.4])
        let entry = await cache.entry(for: track.id)
        XCTAssertEqual(entry?.wordTimingChecked, true)
        XCTAssertEqual(entry?.result, .synced(timed!))

        // Played again: it comes from the cache with the words, no lookup.
        StubURLProtocol.reset()
        let again = await provider().wordTimed(lines, for: track)
        XCTAssertNil(again)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        let cached = await provider().lyrics(for: track)
        XCTAssertEqual(cached, .synced(timed!))
    }

    func testTurnedOffNeverLooksUp() async {
        answer()
        let timed = await provider(enabled: false).wordTimed(lines, for: track)
        XCTAssertNil(timed)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testAFailureIsTriedAgainNextTime() async {
        answer(status: 500)
        let failed = await provider().wordTimed(lines, for: track)
        XCTAssertNil(failed)
        let entry = await cache.entry(for: track.id)
        XCTAssertNotEqual(entry?.wordTimingChecked, true)

        answer()
        let timed = await provider().wordTimed(lines, for: track)
        XCTAssertNotNil(timed)
    }

    func testLinesThatAlreadyHaveWordsAreNotLookedUp() async {
        answer()
        var stamped = lines
        stamped[0].words = [LyricWord(text: "Paper boats", start: 10, end: 11)]
        let timed = await provider().wordTimed(stamped, for: track)
        XCTAssertNil(timed)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }
}
