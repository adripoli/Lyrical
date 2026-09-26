//
//  TitleNormalizer.swift
//  Lyrical
//
//  Spotify titles carry release noise LRCLIB entries usually don't:
//  "Song - 2011 Remaster", "Song (feat. X)", "Song [Explicit]". Used only
//  for the search fallback, so a false strip costs a retry, never a result.
//

import Foundation

enum TitleNormalizer {

    private static let suffixKeywords = [
        "remaster", "live", "version", "edit", "mix", "mono", "stereo", "acoustic",
        "demo", "bonus", "from", "recorded", "session", "single", "deluxe", "anniversary",
    ]
    private static let credit = try! NSRegularExpression(
        pattern: #"\s*[\(\[](?:feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]"#, options: [.caseInsensitive])
    private static let bracketed = try! NSRegularExpression(pattern: #"\s*\[[^\]]*\]"#)

    static func normalize(_ title: String) -> String {
        var result = title

        if let dash = result.range(of: " - ") {
            let suffix = result[dash.upperBound...].lowercased()
            if suffixKeywords.contains(where: { suffix.contains($0) }) {
                result = String(result[..<dash.lowerBound])
            }
        }
        result = strip(credit, from: result)
        result = strip(bracketed, from: result)

        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func strip(_ regex: NSRegularExpression, from string: String) -> String {
        regex.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: "")
    }
}
