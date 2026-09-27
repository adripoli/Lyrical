//
//  main.swift — word-timing evaluation. Built by run.sh together with the
//  app's own WordTiming, WordSync and LRCParser, so it measures the code
//  that ships. Three modes:
//
//    estimate   Give WordTiming only each line's start, as LRC does, and
//               score its guesses against the real word stamps.
//    sync       Lay NetEase's stamps onto LRCLIB's lines for the same song
//               (different line breaks, spelling and clock) and count how
//               many lines take them.
//    synthetic  The same, but with LRCLIB-like lines made from the truth
//               and then disturbed, so the result can be scored exactly.
//

import Foundation

struct Song: Decodable {
    struct Word: Decodable { var text: String; var start: Double; var end: Double }
    struct Line: Decodable { var start: Double; var dur: Double; var words: [Word] }
    var title: String
    var lines: [Line]
    var lrc: String?
}

/// Truth words: one per segment, punctuation-only segments folded into the one before.
func truthWords(_ line: Song.Line) -> [LyricWord] {
    var out: [LyricWord] = []
    for word in line.words {
        let text = word.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { continue }
        if !text.contains(where: { $0.isLetter || $0.isNumber }), !out.isEmpty {
            out[out.count - 1].text += text
            continue
        }
        out.append(LyricWord(text: text, start: word.start, end: word.end))
    }
    return out
}

struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? .nan : sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)]
}

let path = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "build/word-timing-eval/corpus.json"
let songs = try JSONDecoder().decode([Song].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
var rng = Seeded(state: 42)

// MARK: - estimate

/// Word-start error, and the share of sung time the lit word is the right one.
func estimate(jitter: Double) {
    var errors: [Double] = [], endErrors: [Double] = []
    var right = 0.0, total = 0.0
    for song in songs {
        var lines: [LyricLine] = [], truths: [[LyricWord]] = []
        for (index, line) in song.lines.enumerated() {
            let words = truthWords(line)
            guard let first = words.first, let last = words.last else { continue }
            let noise = jitter > 0 ? Double.random(in: -jitter...jitter, using: &rng) : 0
            lines.append(LyricLine(time: first.start + noise, text: words.map(\.text).joined(separator: " "), isGap: false))
            truths.append(words)
            // A long break gets a gap line, as LRC files have.
            if let next = song.lines.dropFirst(index + 1).first?.words.first?.start, next - last.end > 4 {
                lines.append(LyricLine(time: last.end + 0.5, text: "", isGap: true))
                truths.append([])
            }
        }
        for (line, truth) in zip(WordTiming.fill(lines), truths) where !truth.isEmpty {
            guard let guess = line.words, guess.count == truth.count else { continue }
            for (g, t) in zip(guess, truth) {
                errors.append(abs(g.start - t.start))
                endErrors.append(abs(g.end - t.end))
            }
            func lit(_ words: [LyricWord], _ time: Double) -> Int { words.lastIndex { $0.start <= time } ?? -1 }
            var time = truth[0].start
            while time < truth.last!.end {
                if lit(guess, time) == lit(truth, time) { right += 1 }
                total += 1
                time += 0.01
            }
        }
    }
    print(String(format: "estimate (line stamps ±%.2fs): %d words  start error mean %.3fs median %.3fs p90 %.3fs  "
                 + "≤150ms %.1f%%  end error mean %.3fs  right word lit %.1f%%",
                 jitter, errors.count, errors.reduce(0, +) / Double(errors.count), percentile(errors, 0.5),
                 percentile(errors, 0.9), 100 * Double(errors.filter { $0 <= 0.15 }.count) / Double(errors.count),
                 endErrors.reduce(0, +) / Double(endErrors.count), 100 * right / total))
}

// MARK: - sync

func sync() {
    var stamped = 0, sung = 0, unmatched: [String] = []
    var gaps: [Double] = []
    for song in songs {
        guard let lrc = song.lrc else { continue }
        let lines = LRCParser.parse(lrc)
        let segments = song.lines.flatMap { $0.words.map { TimedSegment(text: $0.text, start: $0.start, end: $0.end) } }
        sung += lines.filter { !$0.isGap }.count
        guard let timed = WordSync.attach(segments, to: lines) else { unmatched.append(song.title); continue }
        for line in timed { if let first = line.words?.first { stamped += 1; gaps.append(abs(first.start - line.time)) } }
    }
    print(String(format: "sync: %d of %d LRCLIB lines took real stamps (%.1f%%); first word vs line stamp median %.2fs p90 %.2fs",
                 stamped, sung, 100 * Double(stamped) / Double(sung), percentile(gaps, 0.5), percentile(gaps, 0.9)))
    if !unmatched.isEmpty { print("  no match: \(unmatched.joined(separator: ", "))") }
}

// MARK: - synthetic

/// Lines made from the truth on a clock 1% fast and 3.7 s late, stamps
/// jittered ±0.2 s, some pairs merged; the other side loses 8% of its
/// lines and has some words glued together.
func synthetic() {
    func ours(_ time: Double) -> Double { time * 1.01 + 3.7 }
    var errors: [Double] = [], stamped = 0, total = 0, badLines = 0
    for song in songs {
        let truthLines = song.lines.map(truthWords).filter { !$0.isEmpty }
        var lines: [LyricLine] = [], truths: [[LyricWord]] = []
        var index = 0
        while index < truthLines.count {
            var words = truthLines[index]
            if index + 1 < truthLines.count, Double.random(in: 0..<1, using: &rng) < 0.15 {
                words += truthLines[index + 1]
                index += 1
            }
            let time = ours(words[0].start) + Double.random(in: -0.2...0.2, using: &rng)
            lines.append(LyricLine(time: time, text: words.map(\.text).joined(separator: " "), isGap: false))
            truths.append(words.map { LyricWord(text: $0.text, start: ours($0.start), end: ours($0.end)) })
            index += 1
        }
        var segments: [TimedSegment] = []
        for line in song.lines where Double.random(in: 0..<1, using: &rng) >= 0.08 {
            for word in line.words {
                if Double.random(in: 0..<1, using: &rng) < 0.1, let last = segments.last, last.end >= word.start - 0.01 {
                    segments[segments.count - 1] = TimedSegment(text: last.text.trimmingCharacters(in: .whitespaces) + word.text,
                                                                 start: last.start, end: word.end)
                } else {
                    segments.append(TimedSegment(text: word.text, start: word.start, end: word.end))
                }
            }
        }
        total += lines.count
        guard let timed = WordSync.attach(segments, to: lines) else { continue }
        for (line, truth) in zip(timed, truths) {
            guard let words = line.words, words.count == truth.count else { continue }
            stamped += 1
            let lineErrors = zip(words, truth).map { abs($0.start - $1.start) }
            errors += lineErrors
            if lineErrors.contains(where: { $0 > 1 }) { badLines += 1 }
        }
    }
    print(String(format: "synthetic: %d of %d lines stamped; start error mean %.3fs median %.3fs p90 %.3fs p99 %.3fs; "
                 + "lines with a word >1 s off: %d",
                 stamped, total, errors.reduce(0, +) / Double(errors.count), percentile(errors, 0.5),
                 percentile(errors, 0.9), percentile(errors, 0.99), badLines))
}

switch CommandLine.arguments.dropFirst().first ?? "all" {
case "estimate": estimate(jitter: 0); estimate(jitter: 0.25)
case "sync": sync()
case "synthetic": synthetic()
default: estimate(jitter: 0); estimate(jitter: 0.25); sync(); synthetic()
}
