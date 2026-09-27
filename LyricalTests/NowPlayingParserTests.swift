//
//  NowPlayingParserTests.swift
//  LyricalTests
//
//  The AppleScript reply is untrusted input from another app: fields go missing,
//  ads have no real track, and Spotify hands back a duration in MILLISECONDS
//  while its own dictionary claims seconds. Getting that one wrong makes every
//  progress bar wrong by 1000x, so it's asserted first and loudest.
//

import XCTest
@testable import Lyrical

final class NowPlayingParserTests: XCTestCase {

    /// state, id, name, artist, album, durationMs, positionSec, artworkURL
    private func fields(state: String? = "playing",
                        id: String? = "spotify:track:4uLU6hMCjMI75M1A2tKUQC",
                        name: String? = "Never Gonna Give You Up",
                        artist: String? = "Rick Astley",
                        album: String? = "Whenever You Need Somebody",
                        durationMs: String? = "213000",
                        position: String? = "12.437",
                        artwork: String? = "https://i.scdn.co/image/abc123") -> [String?] {
        [state, id, name, artist, album, durationMs, position, artwork]
    }

    // MARK: - Snapshot

    func testWellFormedFieldsParse() throws {
        let snapshot = try XCTUnwrap(NowPlayingParser.snapshot(fields: fields()))
        let track = try XCTUnwrap(snapshot.track)

        XCTAssertEqual(snapshot.state, .playing)
        XCTAssertEqual(snapshot.position, 12.437, accuracy: 0.0001)
        XCTAssertEqual(track.id, "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(track.name, "Never Gonna Give You Up")
        XCTAssertEqual(track.artist, "Rick Astley")
        XCTAssertEqual(track.album, "Whenever You Need Somebody")
        XCTAssertEqual(track.artworkURL, URL(string: "https://i.scdn.co/image/abc123"))
        XCTAssertFalse(track.isAd)
    }

    /// The one that matters: 213000 ms is 213 s, not 213000 s.
    func testDurationConvertsMillisecondsToSeconds() throws {
        let snapshot = try XCTUnwrap(NowPlayingParser.snapshot(fields: fields(durationMs: "213000")))
        XCTAssertEqual(snapshot.track?.duration, 213.0)
    }

    func testTooFewFieldsIsNil() {
        XCTAssertNil(NowPlayingParser.snapshot(fields: []))
        XCTAssertNil(NowPlayingParser.snapshot(fields: ["playing", "spotify:track:x", "n", "a", "al", "1000", "0"]))
    }

    func testEmptyIDMeansNoTrackButStillReportsStateAndPosition() throws {
        let snapshot = try XCTUnwrap(NowPlayingParser.snapshot(
            fields: fields(state: "paused", id: "", position: "42.5")))

        XCTAssertNil(snapshot.track)
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.position, 42.5, accuracy: 0.0001)
    }

    func testAdvertIsFlagged() throws {
        let snapshot = try XCTUnwrap(NowPlayingParser.snapshot(fields: fields(id: "spotify:ad:xyz")))
        XCTAssertEqual(snapshot.track?.isAd, true)
    }

    func testStateIsCaseInsensitiveAndFallsBackToStopped() throws {
        let upper = try XCTUnwrap(NowPlayingParser.snapshot(fields: fields(state: "Playing")))
        XCTAssertEqual(upper.state, .playing)

        let junk = try XCTUnwrap(NowPlayingParser.snapshot(fields: fields(state: "buffering")))
        XCTAssertEqual(junk.state, .stopped)

        let missing = try XCTUnwrap(NowPlayingParser.snapshot(fields: fields(state: nil)))
        XCTAssertEqual(missing.state, .stopped)
    }

    func testUnparseableNumbersBecomeZero() throws {
        let snapshot = try XCTUnwrap(NowPlayingParser.snapshot(
            fields: fields(durationMs: "«class ldur»", position: nil)))

        XCTAssertEqual(snapshot.track?.duration, 0)
        XCTAssertEqual(snapshot.position, 0)
    }

    func testEmptyTextFieldsSurviveAsEmptyStrings() throws {
        let snapshot = try XCTUnwrap(NowPlayingParser.snapshot(
            fields: fields(name: "", artist: "", album: "", artwork: "")))
        let track = try XCTUnwrap(snapshot.track)

        XCTAssertEqual(track.name, "")
        XCTAssertEqual(track.artist, "")
        XCTAssertEqual(track.album, "")
        XCTAssertNil(track.artworkURL)
    }

    // MARK: - Artwork URL

    func testSpotifyImageURIBecomesCDNURL() {
        XCTAssertEqual(NowPlayingParser.normalizeArtworkURL("spotify:image:abc123"),
                       URL(string: "https://i.scdn.co/image/abc123"))
    }

    func testHTTPSURLPassesThrough() {
        let raw = "https://i.scdn.co/image/ab67616d0000b2735755e35d9ea1e4bfe14c6bce"
        XCTAssertEqual(NowPlayingParser.normalizeArtworkURL(raw), URL(string: raw))
    }

    func testEmptyAndGarbageArtworkAreNil() {
        XCTAssertNil(NowPlayingParser.normalizeArtworkURL(nil))
        XCTAssertNil(NowPlayingParser.normalizeArtworkURL(""))
        XCTAssertNil(NowPlayingParser.normalizeArtworkURL("   "))
        XCTAssertNil(NowPlayingParser.normalizeArtworkURL("spotify:image:"))
        XCTAssertNil(NowPlayingParser.normalizeArtworkURL("file:///Users/adrian/Music/x.mp3"))
        XCTAssertNil(NowPlayingParser.normalizeArtworkURL("missing value"))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(NowPlayingParser.normalizeArtworkURL("  spotify:image:abc123  "),
                       URL(string: "https://i.scdn.co/image/abc123"))
    }

    // MARK: - Light poll

    /// The once-a-second poll only asks for state, track id and position; the
    /// rest of the track comes from the last full poll while the id matches.
    private var known: TrackInfo {
        NowPlayingParser.snapshot(fields: fields())!.track!
    }

    func testLightPollOnTheKnownTrackReusesItsDetails() throws {
        let snapshot = try XCTUnwrap(NowPlayingParser.snapshot(
            light: ["paused", "spotify:track:4uLU6hMCjMI75M1A2tKUQC", "80.5"], known: known))
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.position, 80.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.track, known)
    }

    func testLightPollOnANewTrackAsksForTheFullPoll() {
        XCTAssertNil(NowPlayingParser.snapshot(light: ["playing", "spotify:track:other", "1"], known: known))
        XCTAssertNil(NowPlayingParser.snapshot(light: ["playing", "spotify:track:other", "1"], known: nil))
    }

    func testLightPollWithNoTrackNeedsNothingMore() throws {
        let snapshot = try XCTUnwrap(NowPlayingParser.snapshot(light: ["stopped", "", "0"], known: known))
        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertNil(snapshot.track)
    }

    func testMalformedLightPollAsksForTheFullPoll() {
        XCTAssertNil(NowPlayingParser.snapshot(light: ["playing", "spotify:track:4uLU6hMCjMI75M1A2tKUQC"], known: known))
        XCTAssertNil(NowPlayingParser.snapshot(light: [], known: known))
    }

    /// A track Spotify hasn't finished loading must be asked for again, so its
    /// details land as soon as they exist, as they did when every poll was full.
    func testOnlyTracksWithANameAreRemembered() {
        XCTAssertTrue(NowPlayingParser.isWorthRemembering(known))
        XCTAssertFalse(NowPlayingParser.isWorthRemembering(
            NowPlayingParser.snapshot(fields: fields(name: ""))!.track!))
    }
}
