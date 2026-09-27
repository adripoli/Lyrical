//
//  NetEaseClient.swift
//  Lyrical
//
//  Real word timing from NetEase Cloud Music, which has word-by-word
//  ("YRC") lyrics for a large share of popular songs in every language.
//  Keyless, like LRCLIB. Only used to time words: the lines themselves
//  still come from LRCLIB, and WordSync lays NetEase's stamps onto them.
//  One search matched on title, artist and duration, then one lyrics call.
//

import Foundation

enum WordTimingLookup: Equatable, Sendable {
    case found([TimedSegment])
    /// The song isn't there, or has no word timing. Worth remembering.
    case none
    /// Network or server trouble. Worth trying again another time.
    case failed
}

struct NetEaseClient: Sendable {

    static let baseURL = URL(string: "https://music.163.com/api")!
    static let durationTolerance: TimeInterval = 5
    /// Candidates whose lyrics are fetched before giving up.
    static let maxCandidates = 3

    let session: URLSession

    init(session: URLSession = NetEaseClient.makeSession()) {
        self.session = session
    }

    /// No cookies: once a client holds the cookie its first answer sets,
    /// NetEase's search starts answering with unrelated songs.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func wordTiming(title: String, artist: String, duration: TimeInterval) async -> WordTimingLookup {
        do {
            let title = TitleNormalizer.normalize(title)
            let (data, status) = try await get("search/get", [("s", "\(title) \(artist)"), ("type", "1"), ("limit", "10")])
            guard status == 200 else { return .failed }
            let songs = try JSONDecoder().decode(SearchResponse.self, from: data).result?.songs ?? []

            for song in Self.candidates(songs, title: title, artist: artist, duration: duration)
                .prefix(Self.maxCandidates) {
                let (data, status) = try await get("song/lyric/v1", [("id", String(song.id)), ("lv", "1"), ("yv", "1")])
                guard status == 200 else { return .failed }
                let lyrics = try JSONDecoder().decode(LyricResponse.self, from: data)
                let segments = Self.parseYRC(lyrics.yrc?.lyric ?? "")
                if !segments.isEmpty { return .found(segments) }
            }
            return .none
        } catch {
            NSLog("[Lyrical] NetEase word timing lookup failed: %@", "\(error)")
            return .failed
        }
    }

    // MARK: - Matching

    struct SearchResponse: Decodable {
        struct Result: Decodable { var songs: [Song]? }
        var result: Result?
    }

    struct Song: Decodable, Equatable {
        struct Artist: Decodable, Equatable { var name: String }
        var id: Int
        var name: String
        var artists: [Artist]
        /// Milliseconds.
        var duration: Double?
    }

    struct LyricResponse: Decodable {
        struct Lyric: Decodable { var lyric: String? }
        var yrc: Lyric?
    }

    /// Songs that are this track: same title once release noise is stripped,
    /// an artist in common, and within a few seconds when both durations are
    /// known. Closest duration first.
    static func candidates(_ songs: [Song], title: String, artist: String, duration: TimeInterval) -> [Song] {
        let wantedTitle = key(TitleNormalizer.normalize(title))
        let wantedArtist = key(artist)
        func delta(_ song: Song) -> TimeInterval {
            guard duration > 0, let ms = song.duration else { return 0 }
            return abs(ms / 1000 - duration)
        }
        return songs
            .filter { song in
                // A title that only starts the same ("Song" / "Song (Remastered)")
                // counts when the durations vouch for it.
                let title = key(TitleNormalizer.normalize(song.name))
                let prefixed = title.hasPrefix(wantedTitle) || wantedTitle.hasPrefix(title)
                let timed = duration > 0 && song.duration != nil
                guard !title.isEmpty, !wantedTitle.isEmpty, title == wantedTitle || (prefixed && timed) else {
                    return false
                }
                let artists = song.artists.map { key($0.name) }.filter { !$0.isEmpty }
                guard artists.contains(where: { wantedArtist.contains($0) || $0.contains(wantedArtist) }) else {
                    return false
                }
                return delta(song) <= durationTolerance
            }
            .sorted { delta($0) < delta($1) }
    }

    /// Letters and digits only, lowercased and without accents.
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - YRC

    private static let yrcLine = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
    private static let yrcWord = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)"#)

    /// `[lineStart,lineLength](start,length,0)word (start,length,0)word…`, all
    /// in milliseconds, into segments in the order they're sung. Credit lines
    /// (JSON objects) and anything else without stamps are skipped.
    static func parseYRC(_ text: String) -> [TimedSegment] {
        var segments: [TimedSegment] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let full = NSRange(line.startIndex..., in: line)
            guard yrcLine.firstMatch(in: line, range: full) != nil else { continue }

            let matches = yrcWord.matches(in: line, range: full)
            for (index, match) in matches.enumerated() {
                guard let stamp = Range(match.range, in: line),
                      let start = Range(match.range(at: 1), in: line).flatMap({ Double(line[$0]) }),
                      let length = Range(match.range(at: 2), in: line).flatMap({ Double(line[$0]) }) else { continue }
                let textEnd = index + 1 < matches.count
                    ? Range(matches[index + 1].range, in: line)?.lowerBound ?? line.endIndex
                    : line.endIndex
                let word = String(line[stamp.upperBound..<textEnd])
                guard !word.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                segments.append(TimedSegment(text: word, start: start / 1000, end: (start + length) / 1000))
            }
        }
        return segments.sorted { $0.start < $1.start }
    }

    private func get(_ endpoint: String, _ query: [(String, String)]) async throws -> (Data, Int) {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(endpoint),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
