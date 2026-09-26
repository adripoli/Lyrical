//
//  NowPlaying.swift
//  Lyrical
//
//  Pure value types describing what Spotify is doing. Deliberately free of any
//  AppleScript detail so the parser, the store and the UI can all be tested and
//  reasoned about independently. Durations and positions are SECONDS here —
//  Spotify reports milliseconds, converted once at the parser boundary.
//

import Foundation

enum PlayerState: String, Equatable {
    case playing, paused, stopped
}

struct TrackInfo: Equatable {
    var id: String                 // "spotify:track:…" or "spotify:ad:…"
    var name: String
    var artist: String
    var album: String
    var duration: TimeInterval     // seconds
    var artworkURL: URL?
    var isAd: Bool
}

struct NowPlayingSnapshot: Equatable {
    var state: PlayerState
    var position: TimeInterval     // seconds
    var track: TrackInfo?

    static let idle = NowPlayingSnapshot(state: .stopped, position: 0, track: nil)
}

enum SpotifyAvailability: Equatable {
    case notInstalled, notRunning, running
}

enum TransportCommand: Equatable {
    case playPause, next, previous, seek(TimeInterval)
}

enum AutomationPermissionState: Equatable {
    case granted, denied, undetermined, targetMissing
}

enum SpotifyError: Error, Equatable {
    case notInstalled, notRunning, permissionDenied, permissionUndetermined
    case timedOut, malformedResponse
    case scriptError(code: Int, message: String)
}
