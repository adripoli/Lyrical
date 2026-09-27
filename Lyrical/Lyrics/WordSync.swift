//
//  WordSync.swift
//  Lyrical
//
//  Lays word stamps from another source (NetEase) onto LRCLIB's lines.
//  The two rarely agree on text: lines break in different places, words
//  get glued together or split into syllables, punctuation and spelling
//  drift, backing vocals come and go, and one may have a verse the other
//  lacks. So the match is made letter by letter, over the whole song.
//
//  The clocks can disagree too: a different master or intro shifts every
//  stamp, an edit makes the shift jump, and now and then one source runs
//  a little fast. So it's done twice. The first pass matches letters alone
//  and maps one clock onto the other (ClockMap), ignoring lines that
//  landed far from their neighbours. The second pass only lets a letter
//  match one sung near that map, which is what stops a chorus matching
//  the wrong repeat of itself. A line that disagrees with its neighbours,
//  or whose letters mostly didn't match, keeps no stamps and is estimated.
//

import Foundation

/// A stretch of sung text and when it's sung. Usually a word, sometimes a
/// syllable or a word glued to its neighbour; WordSync copes with all three.
struct TimedSegment: Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

enum WordSync {

    /// Past this many letter pairs the alignment isn't worth its memory.
    static let maxCells = 40_000_000
    /// Share of a line's letters that must match for it to take stamps.
    static let minLineMatch = 0.6
    /// Share of lines that must take stamps, or it's probably another song.
    static let minSongMatch = 0.5
    /// Second pass: how far from the first pass's clock a matched letter may be sung.
    static let trendWindow: TimeInterval = 5
    /// Most one clock may run faster than the other before it's not believed.
    static let maxSpeedDifference = 0.15
    /// Matched lines each side whose clock shifts set a line's shift.
    static let shiftNeighbours = 4
    /// Matched lines each side that a line's shift must agree with to count.
    static let outlierNeighbours = 6
    /// A line whose own shift is further than this from its neighbours'
    /// was matched to the wrong place.
    static let maxShiftDeviation: TimeInterval = 1.5
    static let minWordLength: TimeInterval = 0.05

    /// `lines` with `words` filled from `segments` wherever they match, or
    /// nil if too little matched to trust. Lines that already have words,
    /// and lines that didn't match, are returned unchanged.
    static func attach(_ segments: [TimedSegment], to lines: [LyricLine]) -> [LyricLine]? {
        let (ours, tokens) = letters(of: lines)
        let theirs = letters(of: segments)
        guard !ours.isEmpty, !theirs.isEmpty, ours.count * theirs.count <= maxCells else { return nil }
        // Aligned as small integers: comparing Characters is grapheme-aware
        // and costs far more than the millions of cell updates around it.
        // Equal codes exactly when the Characters are equal, so nothing else changes.
        var codes: [Character: Int32] = [:]
        let code = { (letter: Character) -> Int32 in
            if let known = codes[letter] { return known }
            let new = Int32(codes.count)
            codes[letter] = new
            return new
        }
        let a = ours.map { code($0.letter) }, b = theirs.map { code($0.letter) }

        let rough = lineMatches(align(a, b), ours, theirs)
        guard let guide = ClockMap.fit(anchors(rough, lines)) else { return nil }
        let pairs = align(a, b) { i, j in
            abs(guide.map(theirs[j].start) - ours[i].time) <= trendWindow
        }
        let matches = lineMatches(pairs, ours, theirs)
        guard let clockMap = ClockMap.fit(anchors(matches, lines)) else { return nil }

        var result = lines
        var stamped = 0
        let wanting = lines.filter { !$0.isGap && ($0.words ?? []).isEmpty }.count
        for (index, match) in matches where match.coverage >= minLineMatch && (lines[index].words ?? []).isEmpty {
            guard let words = tokens[index], let reference = match.starts.values.min() else { continue }
            let shift = clockMap.shift(at: reference)
            if match.firstLetterMatched, let first = match.starts[0],
               abs(lines[index].time - first - shift) > maxShiftDeviation { continue }

            // Their clock onto ours: shifted to this line, and stretched if one runs fast.
            let slope = clockMap.slope(at: reference)
            let clock = { (time: TimeInterval) in time + shift + slope * (time - reference) }
            let next = lines.dropFirst(index + 1).first?.time

            // A word keeps its stamp only if most of its letters matched, it
            // falls within the line, and it comes after the word before it.
            // A stray letter matched somewhere else fails one of those.
            var starts: [Int: TimeInterval] = [:], ends: [Int: TimeInterval] = [:]
            var latest = -TimeInterval.infinity
            for token in words.indices {
                guard let start = match.starts[token].map(clock),
                      2 * match.tokenMatched[token, default: 0] >= match.tokenLetters[token, default: 0],
                      start >= lines[index].time - maxShiftDeviation, start <= next ?? .infinity,
                      start >= latest - minWordLength else { continue }
                starts[token] = start
                ends[token] = match.ends[token].map(clock)
                latest = start
            }
            guard !starts.isEmpty else { continue }
            result[index].words = timedWords(words, starts: starts, ends: ends,
                                             lineStart: lines[index].time, nextLine: next)
            stamped += 1
        }
        guard wanting > 0, Double(stamped) >= Double(wanting) * minSongMatch else { return nil }
        return result
    }

    /// Words with the stamps that matched, already on our clock. Words
    /// with no stamp before the first stamped one spread from the line's
    /// start; between stamped words they sit in proportion to where they
    /// fall; after the last one (a backing vocal, or a part the other
    /// source lacks) they're estimated like a line of their own.
    static func timedWords(_ tokens: [String], starts: [Int: TimeInterval], ends: [Int: TimeInterval],
                           lineStart: TimeInterval, nextLine: TimeInterval?) -> [LyricWord] {
        var times = tokens.indices.map { starts[$0] }
        let known = times.indices.filter { times[$0] != nil }
        guard let firstKnown = known.first, let lastKnown = known.last else { return [] }
        let firstTime = times[firstKnown]!
        let lastEnd = max(ends[lastKnown] ?? times[lastKnown]!, times[lastKnown]!)
        let tail = lastKnown < tokens.count - 1
            ? WordTiming.estimate(tokens[(lastKnown + 1)...].joined(separator: " "), start: lastEnd, nextLine: nextLine)
            : []

        for index in times.indices where times[index] == nil {
            if index < firstKnown {
                let lead = min(lineStart, firstTime)
                times[index] = lead + (firstTime - lead) * Double(index) / Double(firstKnown)
            } else if index > lastKnown {
                times[index] = tail[index - lastKnown - 1].start
            } else {
                let before = known.last { $0 < index }!, after = known.first { $0 > index }!
                let share = Double(index - before) / Double(after - before)
                times[index] = times[before]! + (times[after]! - times[before]!) * share
            }
        }
        var ordered: [TimeInterval] = []
        for time in times { ordered.append(max(time!, ordered.last ?? -.infinity)) }

        return tokens.indices.map { index in
            let start = ordered[index]
            guard index == tokens.count - 1 else {
                return LyricWord(text: tokens[index] + " ", start: start, end: ordered[index + 1])
            }
            var end = tail.last?.end ?? lastEnd
            if let nextLine { end = min(end, nextLine) }
            return LyricWord(text: tokens[index], start: start, end: max(end, start + minWordLength))
        }
    }

    // MARK: - Letters

    /// One of our letters: where it is, whether it's a backing vocal (in
    /// parentheses, which the other source often leaves out, so it doesn't
    /// count against the line), and roughly when it's sung.
    struct OurLetter { var letter: Character; var line: Int; var token: Int; var backing: Bool; var time: TimeInterval }
    struct TheirLetter { var letter: Character; var start: TimeInterval; var end: TimeInterval }

    /// A line's letters are assumed spread over its first few seconds; it's
    /// only a guide for the second pass, which allows plenty either side.
    static let letterSpread: TimeInterval = 6

    static func letters(of lines: [LyricLine]) -> ([OurLetter], [Int: [String]]) {
        var ours: [OurLetter] = []
        var tokens: [Int: [String]] = [:]
        for (index, line) in lines.enumerated() where !line.isGap {
            let split = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
            tokens[index] = split
            let count = split.reduce(0) { $0 + letters($1).count }
            let next = lines.dropFirst(index + 1).first?.time ?? line.time + letterSpread
            let span = min(max(next - line.time, 0), letterSpread)
            var depth = 0
            var position = 0
            for (token, text) in split.enumerated() {
                let opens = text.filter { $0 == "(" }.count
                let backing = depth > 0 || opens > 0
                depth = max(depth + opens - text.filter { $0 == ")" }.count, 0)
                for letter in letters(text) {
                    let time = line.time + span * Double(position) / Double(max(count, 1))
                    ours.append(OurLetter(letter: letter, line: index, token: token, backing: backing, time: time))
                    position += 1
                }
            }
        }
        return (ours, tokens)
    }

    static func letters(of segments: [TimedSegment]) -> [TheirLetter] {
        var theirs: [TheirLetter] = []
        for segment in segments {
            let found = letters(segment.text)
            let step = (segment.end - segment.start) / Double(max(found.count, 1))
            for (position, letter) in found.enumerated() {
                let start = segment.start + step * Double(position)
                theirs.append(TheirLetter(letter: letter, start: start, end: start + step))
            }
        }
        return theirs
    }

    /// Letters and digits, lowercased and without accents: what both
    /// sources agree on even when spacing and punctuation don't.
    static func letters(_ text: String) -> [Character] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Lines

    /// How one line matched: how much, and when (on their clock) each
    /// word's first and last matched letters are sung.
    struct LineMatch {
        var letters = 0, matched = 0, leadLetters = 0, leadMatched = 0
        var starts: [Int: TimeInterval] = [:], ends: [Int: TimeInterval] = [:]
        var tokenLetters: [Int: Int] = [:], tokenMatched: [Int: Int] = [:]
        var firstLetterMatched = false
        /// Share of the lead vocal's letters (all letters if it's all backing) that matched.
        var coverage: Double {
            leadLetters > 0 ? Double(leadMatched) / Double(leadLetters) : Double(matched) / Double(max(letters, 1))
        }
    }

    static func lineMatches(_ pairs: [Int?], _ ours: [OurLetter], _ theirs: [TheirLetter]) -> [Int: LineMatch] {
        var matches: [Int: LineMatch] = [:]
        var seen: Set<Int> = []
        for (index, letter) in ours.enumerated() {
            var match = matches[letter.line] ?? LineMatch()
            match.letters += 1
            match.tokenLetters[letter.token, default: 0] += 1
            if !letter.backing { match.leadLetters += 1 }
            let isFirstLetter = seen.insert(letter.line).inserted
            if let other = pairs[index] {
                match.matched += 1
                match.tokenMatched[letter.token, default: 0] += 1
                if !letter.backing { match.leadMatched += 1 }
                if isFirstLetter { match.firstLetterMatched = true }
                if match.starts[letter.token] == nil { match.starts[letter.token] = theirs[other].start }
                match.ends[letter.token] = theirs[other].end
            }
            matches[letter.line] = match
        }
        return matches
    }

    /// A clock sample per well-matched line whose first letter matched:
    /// when they have it sung, and how far our stamp is from that.
    struct Anchor { var line: Int; var time: TimeInterval; var shift: TimeInterval }

    static func anchors(_ matches: [Int: LineMatch], _ lines: [LyricLine]) -> [Anchor] {
        matches.compactMap { index, match in
            guard match.coverage >= minLineMatch, match.firstLetterMatched, let first = match.starts[0],
                  (lines[index].words ?? []).isEmpty else { return nil }
            return Anchor(line: index, time: first, shift: lines[index].time - first)
        }
        .sorted { $0.line < $1.line }
    }

    /// How our clock relates to theirs through the song. Usually a fixed
    /// shift; sometimes it jumps (a different edit) or creeps (one runs a
    /// little fast). An anchor that most of its neighbours disagree with was
    /// matched to the wrong place and is dropped. The rest split into runs
    /// wherever the clock jumps, and within a run each point takes a line
    /// fitted through its neighbours: a smoothed shift and the local drift.
    struct ClockMap {
        struct Point { var time: TimeInterval; var shift: TimeInterval; var slope: Double; var run: Int }
        var points: [Point]

        func map(_ time: TimeInterval) -> TimeInterval { time + shift(at: time) }

        func shift(at time: TimeInterval) -> TimeInterval {
            let after = points.firstIndex { $0.time >= time }
            if let after, after > 0, points[after - 1].run == points[after].run {
                let a = points[after - 1], b = points[after]
                guard b.time > a.time else { return b.shift }
                return a.shift + (b.shift - a.shift) * (time - a.time) / (b.time - a.time)
            }
            let near = nearest(time)
            return near.shift + near.slope * (time - near.time)
        }

        func slope(at time: TimeInterval) -> Double { nearest(time).slope }

        private func nearest(_ time: TimeInterval) -> Point {
            points.min { abs($0.time - time) < abs($1.time - time) }!
        }

        /// Two anchors are on the same clock if their shifts are no further
        /// apart than the slowest believable drift allows.
        static func agree(_ a: Anchor, _ b: Anchor) -> Bool {
            abs(a.shift - b.shift) <= maxShiftDeviation + maxSpeedDifference * abs(a.time - b.time)
        }

        static func fit(_ anchors: [Anchor]) -> ClockMap? {
            let sorted = anchors.sorted { $0.time < $1.time }
            let inliers = sorted.indices.filter { index in
                let others = window(sorted, around: index, outlierNeighbours).filter { $0.line != sorted[index].line }
                return 2 * others.filter { agree($0, sorted[index]) }.count >= others.count
            }.map { sorted[$0] }
            guard !inliers.isEmpty else { return nil }

            var runs: [[Anchor]] = [[inliers[0]]]
            for anchor in inliers.dropFirst() {
                if agree(runs[runs.count - 1].last!, anchor) { runs[runs.count - 1].append(anchor) } else { runs.append([anchor]) }
            }
            var points: [Point] = []
            for (number, run) in runs.enumerated() {
                for index in run.indices {
                    let near = Array(window(run, around: index, shiftNeighbours))
                    var slopes: [Double] = []
                    for (i, a) in near.enumerated() {
                        for b in near[(i + 1)...] where b.time - a.time >= 1 {
                            slopes.append((b.shift - a.shift) / (b.time - a.time))
                        }
                    }
                    let slope = slopes.isEmpty ? 0 : min(max(median(slopes), -maxSpeedDifference), maxSpeedDifference)
                    let intercept = median(near.map { $0.shift - slope * $0.time })
                    let time = run[index].time
                    points.append(Point(time: time, shift: intercept + slope * time, slope: slope, run: number))
                }
            }
            return ClockMap(points: points)
        }

        private static func window(_ anchors: [Anchor], around index: Int, _ radius: Int) -> ArraySlice<Anchor> {
            anchors[max(index - radius, 0)..<min(index + radius + 1, anchors.count)]
        }

        private static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
    }

    // MARK: - Alignment

    /// For each letter of `a`, the letter of `b` it lines up with (only
    /// when they're the same letter, and `allowed` lets them pair). Global
    /// alignment where skipping either side's start or end is free, since
    /// either source may have an extra intro or outro line.
    static func align<Letter: Equatable>(_ a: [Letter], _ b: [Letter],
                                         allowed: ((Int, Int) -> Bool)? = nil) -> [Int?] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [Int?](repeating: nil, count: n) }
        let match: Int32 = 2, mismatch: Int32 = -2, gap: Int32 = -1
        let width = m + 1
        // 0 = pair, 3 = diagonal without pairing, 1 = up (skip a letter of a), 2 = left (skip b).
        var trace = [UInt8](repeating: 0, count: (n + 1) * width)
        var previous = [Int32](repeating: 0, count: width)
        var current = [Int32](repeating: 0, count: width)
        var best: (score: Int32, i: Int, j: Int) = (0, 0, 0)

        for i in 1...n {
            current[0] = 0
            trace[i * width] = 1
            for j in 1...m {
                let pairs = a[i - 1] == b[j - 1] && (allowed?(i - 1, j - 1) ?? true)
                let diagonal = previous[j - 1] + (pairs ? match : mismatch)
                let up = previous[j] + gap
                let left = current[j - 1] + gap
                if diagonal >= up && diagonal >= left {
                    current[j] = diagonal; trace[i * width + j] = pairs ? 0 : 3
                } else if up >= left {
                    current[j] = up; trace[i * width + j] = 1
                } else {
                    current[j] = left; trace[i * width + j] = 2
                }
            }
            // Free end gap on b: the best way to finish a is any column of the last row…
            if i == n { for j in 0...m where current[j] > best.score { best = (current[j], i, j) } }
            // …and a free end gap on a: any row of the last column.
            if current[m] > best.score { best = (current[m], i, m) }
            swap(&previous, &current)
        }

        var pairs = [Int?](repeating: nil, count: n)
        var i = best.i, j = best.j
        while i > 0 && j > 0 {
            switch trace[i * width + j] {
            case 0: pairs[i - 1] = j - 1; i -= 1; j -= 1
            case 3: i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        return pairs
    }
}
