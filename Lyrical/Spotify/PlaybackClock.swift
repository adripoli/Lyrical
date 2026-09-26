//
//  PlaybackClock.swift
//  Lyrical
//
//  Interpolates the playhead between polls so the progress bar moves smoothly at
//  10 Hz off a 1 Hz data source. Anchored to monotonic `systemUptime`, never
//  wall-clock — an NTP correction or a DST jump must not teleport the bar.
//

import Foundation

struct PlaybackClock: Equatable {
    var anchorPosition: TimeInterval = 0
    var anchorUptime: TimeInterval = 0     // ProcessInfo.processInfo.systemUptime
    var duration: TimeInterval = 0
    var isPlaying: Bool = false

    func position(at uptime: TimeInterval) -> TimeInterval {
        let upper = max(duration, 0)
        let raw = isPlaying ? min(upper, anchorPosition + (uptime - anchorUptime)) : anchorPosition
        return min(max(raw, 0), upper)
    }

    /// Re-anchors to a freshly polled position. Returns true if the delta from the
    /// interpolated value exceeded `seekThreshold` (i.e. the user scrubbed externally).
    @discardableResult
    mutating func reanchor(position: TimeInterval, uptime: TimeInterval,
                           isPlaying: Bool, duration: TimeInterval,
                           seekThreshold: TimeInterval = 1.5) -> Bool {
        let drift = abs(position - self.position(at: uptime))

        anchorPosition = position
        anchorUptime = uptime
        self.isPlaying = isPlaying
        self.duration = duration

        return drift > seekThreshold
    }

    /// Progress of the *anchor*, not of now. Use `position(at:)` / `duration` for live UI.
    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(anchorPosition / duration, 0), 1)
    }
}
