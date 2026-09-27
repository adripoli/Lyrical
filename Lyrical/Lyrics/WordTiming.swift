//
//  WordTiming.swift
//  Lyrical
//
//  When each word is sung. Real stamps win when there are any (enhanced
//  LRC, a word-synced Lyricsfile, or NetEase's word timing via WordSync).
//  Most lines only say when they start, so the rest is an estimate, and
//  every constant below was fitted against ~17,000 real word stamps from
//  50 songs (Scripts/word-timing-eval). Two parts:
//
//  - How long the line's words take, first word to last word. Mostly the
//    gap before the next line, tempered by how many syllables and words
//    must fit in it. A chorus that repeats is sung at the same pace every
//    time, so a line takes the tightest gap any of its repeats gets.
//  - How that time is shared. Each word's weight grows with its syllables
//    and letters; small function words are quick, and punctuation means a
//    breath. The last word gets no share: it starts the hold instead.
//
//  Words run legato, each ending as the next starts. The last one is held
//  for most of what's left before the next line.
//
//  Song tempo (BPM) was tried and measured: neither the pace nor snapping
//  to a beat grid got closer to the real stamps, so it isn't used.
//

import Foundation

enum WordTiming {

    // MARK: How long the line takes (log-linear, fitted)

    static let spanBias = -0.862
    static let spanPerLeadSyllables = 0.628   // × ln(syllables before the last word)
    static let spanPerGap = 0.641             // × ln(seconds to the next line)
    static let spanPerSyllables = -0.365      // × ln(all syllables)
    static let spanPerWords = 0.229           // × ln(word count)
    /// The last word's onset never comes later than this share of the gap.
    static let maxSpanShare = 0.864
    /// Gap assumed after the song's last line, and the most any gap counts for.
    static let openGap: TimeInterval = 8
    static let maxGap: TimeInterval = 12

    // MARK: How the time is shared (per word, fitted)

    static let weightBase = 0.45
    static let weightPerSyllable = 0.5
    static let weightPerLetter = 0.1
    static let functionWordWeight = -0.3
    static let shortPauseWeight = 1.3   // after , ; : — -
    static let longPauseWeight = 4.0    // after . ! ? …
    static let firstWordWeight = -0.15
    static let penultimateWordWeight = -0.08
    static let minWeight = 0.05

    // MARK: The held last word

    /// Share of the time left after the last onset that the last word holds.
    static let holdShare = 0.9
    static let maxHold: TimeInterval = 2.5
    static let minWordLength: TimeInterval = 0.1

    static let functionWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "and", "or", "but", "i", "you", "me", "my", "we",
        "he", "she", "it", "is", "am", "are", "was", "be", "at", "for", "so", "as", "with", "your",
        "our", "his", "her", "its", "that", "this", "oh", "uh", "ooh", "ah", "yeah", "no",
    ]

    /// Gives every sung line a `words` array: keeps real stamps (only fixing
    /// an unknown last-word end) and estimates the rest.
    static func fill(_ lines: [LyricLine]) -> [LyricLine] {
        let gaps = lines.indices.map { index in
            lines.dropFirst(index + 1).first.map { $0.time - lines[index].time }
        }
        // The tightest gap each distinct sung text gets anywhere in the song.
        var tightest: [String: TimeInterval] = [:]
        for (line, gap) in zip(lines, gaps) where !line.isGap {
            guard let gap else { continue }
            let key = repeatKey(line.text)
            tightest[key] = min(tightest[key] ?? .infinity, gap)
        }

        return lines.enumerated().map { index, line in
            guard !line.isGap else { return line }
            let next = lines.dropFirst(index + 1).first?.time
            var line = line
            if let words = line.words, !words.isEmpty {
                line.words = closingLastWord(words, before: next)
            } else {
                line.words = estimate(line.text, start: line.time, nextLine: next,
                                      paceGap: tightest[repeatKey(line.text)])
            }
            return line
        }
    }

    /// Splits `text` on whitespace and spreads the words from `start`. Each
    /// word's text keeps its trailing space so the words concatenate back
    /// to the line. `paceGap` is the tightest gap a repeat of this line gets,
    /// which sets its pace when it's tighter than this one's own.
    static func estimate(_ text: String, start: TimeInterval, nextLine: TimeInterval?,
                         paceGap: TimeInterval? = nil) -> [LyricWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let gap = nextLine.map { max($0 - start, 0) }
        let span = tokens.count > 1 ? onsetSpan(tokens, gap: gap, paceGap: paceGap) : 0
        let weights = tokens.indices.dropLast().map { weight(of: tokens[$0], at: $0, of: tokens.count) }
        let total = weights.reduce(0, +)

        var starts = [start]
        for weight in weights { starts.append(starts[starts.count - 1] + span * weight / max(total, minWeight)) }

        let room = (gap ?? openGap) - span
        var lastEnd = starts[starts.count - 1] + min(max(room, 0) * holdShare, maxHold)
        if let nextLine { lastEnd = min(lastEnd, nextLine) }
        lastEnd = max(lastEnd, starts[starts.count - 1] + min(minWordLength, max(room, 0)))

        return tokens.indices.map { index in
            let isLast = index == tokens.count - 1
            return LyricWord(text: isLast ? tokens[index] : tokens[index] + " ",
                             start: starts[index], end: isLast ? lastEnd : starts[index + 1])
        }
    }

    /// Seconds from the first word's onset to the last word's.
    static func onsetSpan(_ tokens: [String], gap: TimeInterval?, paceGap: TimeInterval?) -> TimeInterval {
        let syllableCounts = tokens.map { Double(syllables(in: $0)) }
        let lead = max(syllableCounts.dropLast().reduce(0, +), 1)
        let all = syllableCounts.reduce(0, +)
        let pace = max(min(gap ?? openGap, paceGap ?? .infinity, maxGap), 0.2)
        let span = exp(spanBias + spanPerLeadSyllables * log(lead) + spanPerGap * log(pace)
                       + spanPerSyllables * log(all) + spanPerWords * log(Double(tokens.count)))
        guard let gap else { return span }
        return min(span, gap * maxSpanShare)
    }

    /// A word's share of the line before the last word.
    static func weight(of token: String, at index: Int, of count: Int) -> Double {
        let bare = token.lowercased().filter { $0.isLetter || $0 == "'" || $0 == "’" }
        var weight = weightBase
            + weightPerSyllable * Double(syllables(in: token))
            + weightPerLetter * Double(token.filter(\.isLetter).count)
        if functionWords.contains(bare) { weight += functionWordWeight }
        switch token.last {
        case ",", ";", ":", "—", "-": weight += shortPauseWeight
        case ".", "!", "?", "…": weight += longPauseWeight
        default: break
        }
        if index == 0 { weight += firstWordWeight }
        if index == count - 2 { weight += penultimateWordWeight }
        return max(weight, minWeight)
    }

    /// Vowel groups, a rough syllable count that's good enough for pacing.
    /// A silent trailing "e" doesn't count; every word has at least one.
    static func syllables(in word: String) -> Int {
        let letters = word.lowercased().filter(\.isLetter)
        guard !letters.isEmpty else { return 1 }
        // Scripts without Latin vowels (CJK, etc.): one per character.
        guard letters.contains(where: { $0.isASCII }) else { return letters.count }

        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y", "à", "á", "â", "ä", "è", "é", "ê", "ë",
                                      "ì", "í", "î", "ï", "ò", "ó", "ô", "ö", "ù", "ú", "û", "ü"]
        var count = 0
        var previousWasVowel = false
        for character in letters {
            let isVowel = vowels.contains(character)
            if isVowel && !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }
        if letters.count > 2, letters.hasSuffix("e"), !letters.hasSuffix("le"), count > 1 { count -= 1 }
        return max(count, 1)
    }

    /// Lines that differ only in case and punctuation are the same line sung again.
    static func repeatKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A stamped line whose last word has no end stamp: hold it like an
    /// estimated one would be, cut short if the next line comes first.
    private static func closingLastWord(_ words: [LyricWord], before next: TimeInterval?) -> [LyricWord] {
        guard let last = words.last, last.end <= last.start else { return words }
        var words = words
        let room = next.map { $0 - last.start } ?? openGap
        var end = last.start + min(max(room, 0) * holdShare, maxHold)
        if let next { end = min(end, max(next, last.start)) }
        words[words.count - 1].end = end
        return words
    }
}
