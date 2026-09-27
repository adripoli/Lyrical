//
//  LyricsStoreTests.swift
//  LyricalTests
//

import XCTest
@testable import Lyrical

final class FakeLyricsProvider: LyricsProviding, @unchecked Sendable {
    /// Results handed out in order per track id; the last one repeats.
    var script: [String: [LyricsResult]] = [:]
    var delays: [String: TimeInterval] = [:]
    private(set) var requested: [String] = []
    private(set) var invalidated: [String] = []
    private let lock = NSLock()

    func lyrics(for track: TrackInfo) async -> LyricsResult {
        let result: LyricsResult = lock.withLock {
            requested.append(track.id)
            var queue = script[track.id] ?? [.notFound]
            let next = queue.first ?? .notFound
            if queue.count > 1 { queue.removeFirst() }
            script[track.id] = queue
            return next
        }
        if let delay = delays[track.id] { try? await Task.sleep(for: .seconds(delay)) }
        return result
    }

    /// Word-timed lines handed out after the lines, per track id.
    var timed: [String: [LyricLine]] = [:]

    func wordTimed(_ lines: [LyricLine], for track: TrackInfo) async -> [LyricLine]? {
        lock.withLock { timed[track.id] }
    }

    func invalidate(trackID: String) async {
        lock.withLock { invalidated.append(trackID) }
    }
}

@MainActor
final class LyricsStoreTests: XCTestCase {

    private var provider: FakeLyricsProvider!
    private var store: LyricsStore!
    private var fakeNow: TimeInterval = 1_000
    private var fakeOffset: TimeInterval = 0

    private let lines = [
        LyricLine(time: 10, text: "a", isGap: false),
        LyricLine(time: 14, text: "b", isGap: false),
        LyricLine(time: 18, text: "c", isGap: false),
        LyricLine(time: 22, text: "d", isGap: false),
        LyricLine(time: 26, text: "e", isGap: false),
    ]

    override func setUp() async throws {
        provider = FakeLyricsProvider()
        fakeNow = 1_000
        fakeOffset = 0
        store = LyricsStore(provider: provider,
                            offset: { [unowned self] in self.fakeOffset },
                            now: { [unowned self] in self.fakeNow },
                            retryDelay: 0.05)
    }

    override func tearDown() async throws {
        store.stop()
    }

    private func track(_ id: String, isAd: Bool = false, duration: TimeInterval = 100) -> TrackInfo {
        TrackInfo(id: id, name: "Song \(id)", artist: "Artist", album: "Album",
                  duration: duration, artworkURL: nil, isAd: isAd)
    }

    private func play(at position: TimeInterval, duration: TimeInterval = 100, playing: Bool = true) {
        store.setClock(PlaybackClock(anchorPosition: position, anchorUptime: fakeNow,
                                     duration: duration, isPlaying: playing))
    }

    // Index 0 is the intro gap withIntroGap inserts (first line is at 10 s).
    private func loadSynced(_ id: String = "t") async {
        provider.script[id] = [.synced(lines)]
        store.setTrack(track(id))
        await store.waitForPendingFetch()
    }

    func testAdvertisementSkipsNetwork() {
        store.setTrack(track("ad", isAd: true))
        XCTAssertEqual(store.state, .advertisement)
        XCTAssertTrue(provider.requested.isEmpty)
    }

    func testLoadingThenSyncedWithIntroGap() async {
        provider.script["t"] = [.synced(lines)]
        store.setTrack(track("t"))
        XCTAssertEqual(store.state, .loading)

        await store.waitForPendingFetch()

        XCTAssertEqual(store.state, .loaded(.synced(WordTiming.fill(LyricsTimeline.withIntroGap(lines)))))
        XCTAssertEqual(store.lines.first?.isGap, true)
    }

    func testRealWordTimingReplacesTheEstimateOnceItArrives() async {
        var timed = lines
        timed[0].words = [LyricWord(text: "a", start: 10.3, end: 11)]
        provider.script["t"] = [.synced(lines)]
        provider.timed["t"] = timed
        store.setTrack(track("t"))
        await store.waitForPendingFetch()

        XCTAssertEqual(store.state, .loaded(.synced(WordTiming.fill(LyricsTimeline.withIntroGap(timed)))))
        XCTAssertEqual(store.lines[1].words?.first?.start, 10.3)
    }

    func testActiveIndexFollowsClockAndAdvances() async {
        await loadSynced()
        play(at: 11)
        XCTAssertEqual(store.activeIndex, 1)

        fakeNow += 3.5
        store.resync()
        XCTAssertEqual(store.activeIndex, 2)
        XCTAssertEqual(store.lastMove, .advance)
    }

    func testOffsetShiftsTheActiveLine() async {
        await loadSynced()
        play(at: 13.8)
        XCTAssertEqual(store.activeIndex, 1)

        fakeOffset = 0.25
        store.resync()
        XCTAssertEqual(store.activeIndex, 2)
    }

    func testSeekBackwardIsAJump() async {
        await loadSynced()
        play(at: 19)
        play(at: 11)
        XCTAssertEqual(store.activeIndex, 1)
        XCTAssertEqual(store.lastMove, .jump)
    }

    func testLargeForwardSkipIsAJump() async {
        await loadSynced()
        play(at: 11)
        play(at: 27)
        XCTAssertEqual(store.activeIndex, 5)
        XCTAssertEqual(store.lastMove, .jump)
    }

    func testMoveClassification() {
        XCTAssertEqual(LyricsStore.move(from: nil, to: 0), .advance)
        XCTAssertEqual(LyricsStore.move(from: 2, to: 3), .advance)
        XCTAssertEqual(LyricsStore.move(from: 2, to: 5), .advance)
        XCTAssertEqual(LyricsStore.move(from: 2, to: 6), .jump)
        XCTAssertEqual(LyricsStore.move(from: 4, to: 1), .jump)
        XCTAssertEqual(LyricsStore.move(from: 4, to: nil), .jump)
    }

    func testRepeatOneReturnsToTopWithoutRefetch() async {
        await loadSynced()
        play(at: 50)
        XCTAssertEqual(store.activeIndex, 5)

        store.setTrack(track("t"))   // same id: Spotify's repeat-one
        play(at: 0.2)

        XCTAssertEqual(store.activeIndex, 0)
        XCTAssertEqual(store.lastMove, .jump)
        XCTAssertEqual(provider.requested, ["t"])
    }

    func testStaleResultIsDropped() async throws {
        provider.script["slow"] = [.synced(lines)]
        provider.delays["slow"] = 0.3
        provider.script["fast"] = [.notFound]

        store.setTrack(track("slow"))
        store.setTrack(track("fast"))
        await store.waitForPendingFetch()
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(store.track?.id, "fast")
        XCTAssertEqual(store.state, .loaded(.notFound))
    }

    func testRapidSkipsOnlyLastTrackLands() async throws {
        let ids = ["one", "two", "three", "four", "five"]
        for (index, id) in ids.enumerated() {
            provider.script[id] = [.plain("lyrics for \(id)")]
            provider.delays[id] = 0.05 * Double(ids.count - index)   // earlier tracks answer later
        }

        for id in ids { store.setTrack(track(id)) }
        await store.waitForPendingFetch()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(store.state, .loaded(.plain("lyrics for five")))
    }

    func testFailedRetriesUntilItSucceeds() async throws {
        provider.script["t"] = [.failed, .synced(lines)]
        store.setTrack(track("t"))
        await store.waitForPendingFetch()
        XCTAssertEqual(store.state, .loaded(.failed))

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(store.state, .loaded(.synced(WordTiming.fill(LyricsTimeline.withIntroGap(lines)))))
        XCTAssertEqual(provider.requested, ["t", "t"])
    }

    func testReloadInvalidatesAndRefetches() async {
        await loadSynced()
        store.reload()
        XCTAssertEqual(store.state, .loading)
        await store.waitForPendingFetch()

        XCTAssertEqual(provider.invalidated, ["t"])
        XCTAssertEqual(provider.requested, ["t", "t"])
    }

    func testTickScheduledOnlyWhilePlaying() async {
        await loadSynced()
        play(at: 11, playing: false)
        XCTAssertFalse(store.hasPendingTick)
        play(at: 11, playing: true)
        XCTAssertTrue(store.hasPendingTick)
    }

    func testNoTickScheduledPastTrackEnd() async {
        provider.script["short"] = [.synced([
            LyricLine(time: 1, text: "a", isGap: false),
            LyricLine(time: 30, text: "after the end", isGap: false),
        ])]
        store.setTrack(track("short", duration: 20))
        await store.waitForPendingFetch()

        play(at: 5, duration: 20)

        XCTAssertFalse(store.hasPendingTick)
    }

    func testClearingTrackGoesIdle() async {
        await loadSynced()
        store.setTrack(nil)
        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.activeIndex)
    }
}
