//
//  Lyricsfile.swift
//  Lyrical
//
//  LRCLIB's newer lyrics format (https://lrclib.net/lyricsfile): YAML with
//  per-line and, when someone has synced them, per-word millisecond
//  stamps. Read only for its words; lines alone are no better than the LRC
//  that comes alongside. The format keeps to plain block-style YAML, which
//  is all the small reader below understands. Anything else is nil, and
//  the LRC is used instead.
//

import Foundation

enum Lyricsfile {

    /// Lines with real word timing, or nil if the document has none or
    /// can't be read. Empty lines become gaps, as in LRC.
    static func wordSyncedLines(from document: String) -> [LyricLine]? {
        guard let root = YAML.parse(document)?.mapping,
              root["version"]?.string?.hasPrefix("1.") == true,
              let lines = root["lines"]?.sequence else { return nil }

        var result: [LyricLine] = []
        for node in lines {
            guard let line = node.mapping, let startMs = line["start_ms"]?.number else { return nil }
            let words = (line["words"]?.sequence ?? []).compactMap { node -> LyricWord? in
                guard let word = node.mapping, let text = word["text"]?.string,
                      let start = word["start_ms"]?.number else { return nil }
                let end = word["end_ms"]?.number ?? start
                return LyricWord(text: text, start: start / 1000, end: max(end, start) / 1000)
            }
            let tidied = tidy(words)
            let text = tidied.isEmpty
                ? (line["text"]?.string ?? "").trimmingCharacters(in: .whitespaces)
                : tidied.map(\.text).joined()
            result.append(LyricLine(time: startMs / 1000, text: text, isGap: text.isEmpty,
                                    words: tidied.isEmpty ? nil : tidied))
        }
        guard result.contains(where: { $0.words != nil }) else { return nil }
        // Sorted, with a run of empty lines kept as one gap, as LRCParser does.
        var tidied: [LyricLine] = []
        for line in result.sorted(by: { $0.time < $1.time }) where !(line.isGap && tidied.last?.isGap == true) {
            tidied.append(line)
        }
        return tidied
    }

    /// Same shape LRCParser gives enhanced LRC: blank words folded into the
    /// word before, no space before the first word or after the last, and a
    /// missing end (== start) filled from the next word's start.
    private static func tidy(_ words: [LyricWord]) -> [LyricWord] {
        var result: [LyricWord] = []
        for word in words.sorted(by: { $0.start < $1.start }) {
            if word.text.trimmingCharacters(in: .whitespaces).isEmpty {
                if !result.isEmpty { result[result.count - 1].text += word.text }
                continue
            }
            result.append(word)
        }
        guard !result.isEmpty else { return [] }
        for index in result.indices.dropLast() where result[index].end <= result[index].start {
            result[index].end = max(result[index + 1].start, result[index].start)
        }
        result[0].text = String(result[0].text.drop(while: \.isWhitespace))
        while result[result.count - 1].text.last?.isWhitespace == true { result[result.count - 1].text.removeLast() }
        return result
    }
}

/// Just enough YAML for a Lyricsfile: block mappings and sequences (the
/// `- ` items may sit at or inside their key's indent), plain, single- and
/// double-quoted scalars on one line, `|` and `>` block scalars, comments.
/// Flow collections, anchors, tags and multi-line quoted scalars are not
/// supported and make the whole parse fail rather than guess.
indirect enum YAML: Equatable {
    case scalar(String)
    case mapping([String: YAML])
    case sequence([YAML])
    case null

    var mapping: [String: YAML]? { if case .mapping(let value) = self { return value } else { return nil } }
    var sequence: [YAML]? { if case .sequence(let value) = self { return value } else { return nil } }
    var string: String? { if case .scalar(let value) = self { return value } else { return nil } }
    var number: Double? { string.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }

    static func parse(_ text: String) -> YAML? {
        var parser = Parser(text)
        return parser.document()
    }

    private struct Line {
        var indent: Int
        var content: Substring
    }

    private struct Parser {
        var lines: [Line] = []
        var rawLines: [Substring]
        var rawIndex: [Int] = []   // which raw line each entry came from, for block scalars
        var position = 0
        var failed = false

        init(_ text: String) {
            rawLines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            for (index, raw) in rawLines.enumerated() {
                let indent = raw.prefix { $0 == " " }.count
                let content = raw.dropFirst(indent)
                if content.isEmpty || content.hasPrefix("#") || content == "---" || content == "..." { continue }
                lines.append(Line(indent: indent, content: content))
                rawIndex.append(index)
            }
        }

        mutating func document() -> YAML? {
            guard !lines.isEmpty else { return .null }
            let node = block(indent: lines[0].indent)
            return failed || position < lines.count ? nil : node
        }

        /// The node whose lines start at the current position, all at `indent`.
        mutating func block(indent: Int) -> YAML {
            guard position < lines.count else { return .null }
            let line = lines[position]
            if line.content == "-" || line.content.hasPrefix("- ") { return sequence(indent: indent) }
            if Self.splitKey(line.content) != nil { return mapping(indent: indent) }
            position += 1
            return scalar(line.content)
        }

        mutating func sequence(indent: Int) -> YAML {
            var items: [YAML] = []
            while position < lines.count, lines[position].indent == indent, !failed {
                let content = lines[position].content
                guard content == "-" || content.hasPrefix("- ") else { break }
                let rest = content.dropFirst(content == "-" ? 1 : 2)
                let restIndent = indent + (content.count - rest.count) + rest.prefix { $0 == " " }.count
                let trimmed = rest.drop { $0 == " " }
                if trimmed.isEmpty {
                    position += 1
                    items.append(position < lines.count && lines[position].indent > indent
                                 ? block(indent: lines[position].indent) : .null)
                } else {
                    // "- key: value" starts a mapping indented as far as its key.
                    lines[position] = Line(indent: restIndent, content: trimmed)
                    items.append(block(indent: restIndent))
                }
            }
            return .sequence(items)
        }

        mutating func mapping(indent: Int) -> YAML {
            var result: [String: YAML] = [:]
            while position < lines.count, lines[position].indent == indent, !failed {
                let content = lines[position].content
                guard content != "-", !content.hasPrefix("- "), let (key, value) = Self.splitKey(content) else { break }
                guard result[key] == nil else { failed = true; break }   // duplicate keys aren't allowed
                let raw = rawIndex[position]
                position += 1
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("|") || trimmed.hasPrefix(">") {
                    result[key] = .scalar(blockScalar(after: raw, parentIndent: indent, folded: trimmed.hasPrefix(">")))
                } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    result[key] = scalar(Substring(trimmed))
                } else if position < lines.count, lines[position].indent > indent {
                    result[key] = block(indent: lines[position].indent)
                } else if position < lines.count, lines[position].indent == indent,
                          lines[position].content == "-" || lines[position].content.hasPrefix("- ") {
                    // A sequence may sit at its key's own indent.
                    result[key] = sequence(indent: indent)
                } else {
                    result[key] = .null
                }
            }
            return .mapping(result)
        }

        /// The more-indented raw lines after `raw`, as text.
        mutating func blockScalar(after raw: Int, parentIndent: Int, folded: Bool) -> String {
            var collected: [Substring] = []
            var index = raw + 1
            var contentIndent: Int?
            while index < rawLines.count {
                let line = rawLines[index]
                let indent = line.prefix { $0 == " " }.count
                if line.allSatisfy({ $0 == " " }) { collected.append(""); index += 1; continue }
                guard indent > parentIndent else { break }
                contentIndent = contentIndent ?? indent
                collected.append(line.dropFirst(min(indent, contentIndent!)))
                index += 1
            }
            while position < lines.count, rawIndex[position] < index { position += 1 }
            while collected.last?.isEmpty == true { collected.removeLast() }
            return collected.joined(separator: folded ? " " : "\n") + "\n"
        }

        mutating func scalar(_ content: Substring) -> YAML {
            let text = content.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("'") {
                guard let value = Self.singleQuoted(text) else { failed = true; return .null }
                return .scalar(value)
            }
            if text.hasPrefix("\"") {
                guard let value = Self.doubleQuoted(text) else { failed = true; return .null }
                return .scalar(value)
            }
            if text.hasPrefix("[") || text.hasPrefix("{") || text.hasPrefix("&") || text.hasPrefix("*") || text.hasPrefix("!") {
                if text == "[]" { return .sequence([]) }
                if text == "{}" { return .mapping([:]) }
                failed = true
                return .null
            }
            var plain = text
            if let comment = plain.range(of: " #") { plain = String(plain[..<comment.lowerBound]) }
            plain = plain.trimmingCharacters(in: .whitespaces)
            return plain == "~" || plain == "null" || plain.isEmpty ? .null : .scalar(plain)
        }

        /// `key: value` or `key:` outside quotes, with the key unquoted.
        static func splitKey(_ content: Substring) -> (String, Substring)? {
            var inSingle = false, inDouble = false
            var index = content.startIndex
            while index < content.endIndex {
                let character = content[index]
                if character == "'" && !inDouble { inSingle.toggle() }
                if character == "\"" && !inSingle { inDouble.toggle() }
                if character == ":" && !inSingle && !inDouble {
                    let after = content.index(after: index)
                    if after == content.endIndex || content[after] == " " {
                        let rawKey = content[..<index].trimmingCharacters(in: .whitespaces)
                        let key = rawKey.hasPrefix("'") ? singleQuoted(rawKey)
                            : rawKey.hasPrefix("\"") ? doubleQuoted(rawKey) : rawKey
                        guard let key, !key.isEmpty else { return nil }
                        return (key, content[after...])
                    }
                }
                index = content.index(after: index)
            }
            return nil
        }

        /// 'it''s' → it's. nil unless the quotes close at the end (bar a comment).
        static func singleQuoted(_ text: String) -> String? {
            var result = ""
            var index = text.index(after: text.startIndex)
            while index < text.endIndex {
                let character = text[index]
                let next = text.index(after: index)
                if character == "'" {
                    if next < text.endIndex, text[next] == "'" { result.append("'"); index = text.index(after: next); continue }
                    return trailerIsEmpty(text[next...]) ? result : nil
                }
                result.append(character)
                index = next
            }
            return nil
        }

        static func doubleQuoted(_ text: String) -> String? {
            var result = ""
            var index = text.index(after: text.startIndex)
            while index < text.endIndex {
                let character = text[index]
                var next = text.index(after: index)
                if character == "\"" { return trailerIsEmpty(text[next...]) ? result : nil }
                if character == "\\", next < text.endIndex {
                    let escaped = text[next]
                    next = text.index(after: next)
                    switch escaped {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "\\", "\"", "/": result.append(escaped)
                    case "u":
                        let hex = text[next...].prefix(4)
                        guard hex.count == 4, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
                        result.unicodeScalars.append(scalar)
                        next = text.index(next, offsetBy: 4)
                    default: result.append(escaped)
                    }
                    index = next
                    continue
                }
                result.append(character)
                index = next
            }
            return nil
        }

        private static func trailerIsEmpty(_ rest: Substring) -> Bool {
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }
    }
}
