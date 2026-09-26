//
//  LyricsTimeline.swift
//  Lyrical
//
//  Which line is being sung, and when the next one starts. `offset` is the
//  lead in seconds: a positive offset makes each line arrive early so the
//  carousel's spring has settled by the time the singer gets there.
//

import Foundation

enum LyricsTimeline {

    /// A song that sings nothing for this long opens on breathing dots
    /// instead of a line of text that won't be sung for a while.
    static let introGapThreshold: TimeInterval = 4

    /// Index of the line being sung at `position`, or nil before the first line.
    static func activeIndex(in lines: [LyricLine], at position: TimeInterval, offset: TimeInterval) -> Int? {
        let t = position + offset
        // First index whose time is strictly after t.
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= t { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// Playback position at which the next line takes over, or nil after the last line.
    static func nextBoundary(in lines: [LyricLine], at position: TimeInterval, offset: TimeInterval) -> TimeInterval? {
        let next = activeIndex(in: lines, at: position, offset: offset).map { $0 + 1 } ?? 0
        guard next < lines.count else { return nil }
        return lines[next].time - offset
    }

    static func withIntroGap(_ lines: [LyricLine]) -> [LyricLine] {
        guard let first = lines.first, !first.isGap, first.time > introGapThreshold else { return lines }
        return [LyricLine(time: 0, text: "", isGap: true)] + lines
    }
}
