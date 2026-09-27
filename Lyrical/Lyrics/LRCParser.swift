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
    /// Enhanced-LRC word timing (`<00:01.50>`): each stamp starts the text after it.
    private static let wordStamp = try! NSRegularExpression(
        pattern: #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#)

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
            let words = lyric.isEmpty ? nil : wordTimings(in: rest, lineTime: stamps[0])
            for time in stamps {
                // A repeated line (`[00:10][01:40]...`) reuses the same word
                // rhythm, shifted to each of its starts.
                let shifted = words?.map { LyricWord(text: $0.text, start: $0.start - stamps[0] + time,
                                                     end: $0.end - stamps[0] + time) }
                lines.append(LyricLine(time: time, text: lyric, isGap: lyric.isEmpty, words: shifted))
            }
        }

        // `[offset:+N]` means "show N ms earlier" and covers the whole file,
        // wherever the tag sits.
        if offset != 0 {
            lines = lines.map { line in
                let words = line.words?.map {
                    LyricWord(text: $0.text, start: max(0, $0.start - offset), end: max(0, $0.end - offset))
                }
                return LyricLine(time: max(0, line.time - offset), text: line.text, isGap: line.isGap, words: words)
            }
        }
        return tidy(lines)
    }

    /// Words from enhanced-LRC stamps, or nil if the line has none. Each
    /// stamp's text runs until the next stamp; a trailing stamp with no text
    /// marks when the last word ends. A last word with no such stamp gets
    /// `end == start`, which WordTiming fills in later.
    private static func wordTimings(in text: String, lineTime: TimeInterval) -> [LyricWord]? {
        let matches = wordStamp.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return nil }

        var segments: [(start: TimeInterval, text: String)] = []
        var cursor = text.startIndex
        var start = lineTime
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            segments.append((start, String(text[cursor..<range.lowerBound])))
            start = seconds(from: match, in: text)
            cursor = range.upperBound
        }
        segments.append((start, String(text[cursor...])))

        // Word text keeps its own trailing space, so the words concatenated
        // are exactly the line, and syllable stamps (`<..>hel<..>lo`) don't
        // grow a space in the middle of a word.
        var words: [LyricWord] = []
        for (index, segment) in segments.enumerated() {
            guard !segment.text.trimmingCharacters(in: .whitespaces).isEmpty else {
                if !words.isEmpty { words[words.count - 1].text += segment.text }
                continue
            }
            let next = segments.dropFirst(index + 1).first?.start ?? segment.start
            words.append(LyricWord(text: segment.text, start: segment.start, end: max(next, segment.start)))
        }
        guard !words.isEmpty else { return nil }
        words[0].text = String(words[0].text.drop(while: \.isWhitespace))
        while words[words.count - 1].text.last?.isWhitespace == true { words[words.count - 1].text.removeLast() }
        return words
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
