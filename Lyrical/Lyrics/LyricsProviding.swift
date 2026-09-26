//
//  LyricsProviding.swift
//  Lyrical
//
//  The seam between LyricsStore and where lyrics come from. The real one
//  checks the disk cache, then asks LRCLIB. The mock (LYRICAL_MOCK=1) serves
//  invented lyrics for the invented mock playlist, so every wallpaper state
//  can be demoed offline. None of the text below is from a real song.
//

import Foundation

protocol LyricsProviding: Sendable {
    func lyrics(for track: TrackInfo) async -> LyricsResult
    func invalidate(trackID: String) async
}

struct CachedLyricsProvider: LyricsProviding {
    let client: LRCLIBClient
    let cache: LyricsCache

    func lyrics(for track: TrackInfo) async -> LyricsResult {
        if let cached = await cache.result(for: track.id) { return cached }
        let result = await client.lyrics(title: track.name, artist: track.artist,
                                         album: track.album, duration: track.duration)
        await cache.store(result, for: track.id)   // ignores .failed
        return result
    }

    func invalidate(trackID: String) async {
        await cache.remove(trackID: trackID)
    }
}

struct MockLyricsProvider: LyricsProviding {

    private static let lyrics: [String: LyricsResult] = [
        "spotify:track:lyricalmock0001": .synced(LRCParser.parse("""
        [00:06.00]Paper lanterns drifting over the river
        [00:10.00]Every one a question nobody asked
        [00:14.00]I wrote your name in pencil on the water
        [00:18.00]And watched the current carry it past
        [00:22.00]Hold the light a little longer
        [00:26.00]Hold the light
        [00:30.00]
        [00:36.00]Paper lanterns, paper lanterns
        [00:40.00]Folding up the evening into squares
        [00:44.00]If the wind should ask where we were going
        [00:48.00]Tell it we were already there
        [00:52.00]Hold the light a little longer
        [00:56.00]Hold the light
        """)),
        "spotify:track:lyricalmock0002": .synced(LRCParser.parse("""
        [00:02.00]Radio hiss on the northbound line
        [00:05.50]Counting the towns by the lights that remain
        [00:09.00]This is a deliberately long line that only exists to prove the carousel wraps text across more than one row without breaking the spacing
        [00:15.00]Static, static
        [00:18.00]Tune me in
        [00:21.00]Somewhere between the stations
        [00:25.00]Somebody's humming along
        [00:29.00]
        [00:33.00]Static, static
        [00:36.00]Tune me in
        [00:40.00]Northbound, northbound
        [00:44.00]Till the signal's gone
        """)),
        "spotify:track:lyricalmock0003": .instrumental,
        "spotify:track:lyricalmock0004": .notFound,
    ]

    func lyrics(for track: TrackInfo) async -> LyricsResult {
        // Long enough to see the "Loading lyrics…" card, short enough not to annoy.
        try? await Task.sleep(for: .milliseconds(600))
        return Self.lyrics[track.id] ?? .notFound
    }

    func invalidate(trackID: String) async {}
}
