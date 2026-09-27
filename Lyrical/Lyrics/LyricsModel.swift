//
//  LyricsModel.swift
//  Lyrical
//
//  Pure value types for lyrics. `LyricsResult` is what a lookup produced (and
//  what the disk cache stores verbatim); `LyricsState` is what the wallpaper
//  should be showing right now.
//

import Foundation

/// One timed line. `isGap` marks an instrumental break (an empty LRC line),
/// drawn as breathing dots rather than text. `words` is per-word timing:
/// real when the LRC had enhanced `<mm:ss.xx>` stamps, otherwise estimated
/// by WordTiming. Optional so caches written before it existed still decode.
struct LyricLine: Codable, Equatable, Sendable {
    var time: TimeInterval
    var text: String
    var isGap: Bool
    var words: [LyricWord]? = nil
}

/// One sung word and when it's sung. `end` is when the voice moves on.
struct LyricWord: Codable, Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

enum LyricsResult: Codable, Equatable, Sendable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
    /// Network or server trouble. Never cached; the store retries it.
    case failed
}

enum LyricsState: Equatable {
    case idle
    case loading
    case advertisement
    case loaded(LyricsResult)
}
