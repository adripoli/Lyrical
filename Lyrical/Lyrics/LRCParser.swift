//
//  LRCParser.swift
//  Lyrical
//
//  LRC text → sorted, tidy [LyricLine]. Tolerant by design: LRCLIB is
//  crowd-sourced, so anything that isn't a timestamped line is skipped rather
//  than failing the whole file.
//

import Foundation

enum LRCParser {

    private static let stamp = try! NSRegularExpression(
        pattern: #"^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let offsetTag = try! NSRegularExpression(
        pattern: #"^\[offset:\s*([+-]?\d+)\s*\]$"#, options: [.caseInsensitive])
    /// Enhanced-LRC word timing (`<00:01.50>`). We only do line-level sync.
    private static let wordStamp = try! NSRegularExpression(
        pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)

    static func parse(_ text: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var lines: [LyricLine] = []

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for raw in normalized.split(separator: "\n") {
            var rest = raw.trimmingCharacters(in: .whitespaces)

            if let ms = firstCapture(offsetTag, in: rest).flatMap(Double.init) {
                offset = ms / 1000
                continue
            }

            var stamps: [TimeInterval] = []
            while let match = stamp.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let range = Range(match.range, in: rest) {
                stamps.append(seconds(from: match, in: rest))
                rest = String(rest[range.upperBound...])
            }
            guard !stamps.isEmpty else { continue }   // metadata tag or junk

            let lyric = wordStamp
                .stringByReplacingMatches(in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            for time in stamps {
                lines.append(LyricLine(time: time, text: lyric, isGap: lyric.isEmpty))
            }
        }

        // `[offset:+N]` means "show N ms earlier" and covers the whole file,
        // wherever the tag sits.
        if offset != 0 {
            lines = lines.map { LyricLine(time: max(0, $0.time - offset), text: $0.text, isGap: $0.isGap) }
        }
        return tidy(lines)
    }

    /// Stable sort by time, drop exact duplicates, collapse runs of gaps.
    private static func tidy(_ lines: [LyricLine]) -> [LyricLine] {
        let sorted = lines.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)

        var result: [LyricLine] = []
        for line in sorted {
            if let last = result.last, last == line || (last.isGap && line.isGap) { continue }
            result.append(line)
        }
        return result
    }

    private static func seconds(from match: NSTextCheckingResult, in string: String) -> TimeInterval {
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: string).map { String(string[$0]) }
        }
        let minutes = group(1).flatMap(Double.init) ?? 0
        let secs = group(2).flatMap(Double.init) ?? 0
        let fraction = group(3).flatMap { Double("0.\($0)") } ?? 0
        return minutes * 60 + secs + fraction
    }

    private static func firstCapture(_ regex: NSRegularExpression, in string: String) -> String? {
        guard let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[range])
    }
}
