//
//  LRCLIBClient.swift
//  Lyrical
//
//  https://lrclib.net — free, keyless, line-synced lyrics. One exact lookup
//  (/api/get) and, on a miss, one fuzzy search with a cleaned-up title
//  matched on duration. Never throws: every outcome is a LyricsResult, and
//  anything network-shaped is `.failed` so the store knows to retry.
//

import Foundation

struct LRCLIBRecord: Decodable, Equatable {
    var duration: Double?
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?

    init(duration: Double? = nil, instrumental: Bool? = nil,
         plainLyrics: String? = nil, syncedLyrics: String? = nil) {
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }

    var hasSynced: Bool { !(syncedLyrics ?? "").isEmpty }
}

struct LRCLIBClient: Sendable {

    static let baseURL = URL(string: "https://lrclib.net/api")!
    static let durationTolerance: TimeInterval = 3

    let session: URLSession
    let userAgent: String

    init(session: URLSession = LRCLIBClient.makeSession(), userAgent: String = LRCLIBClient.defaultUserAgent) {
        self.session = session
        self.userAgent = userAgent
    }

    /// LRCLIB asks clients to identify themselves.
    static var defaultUserAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Lyrical/\(version) (https://github.com/adripoli/Lyrical)"
    }

    /// LyricsCache owns caching, so URLSession's would be dead weight.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func lyrics(title: String, artist: String, album: String, duration: TimeInterval) async -> LyricsResult {
        do {
            // /api/get needs a duration; without one, go straight to search.
            guard duration > 0 else { return try await search(title: title, artist: artist, duration: duration) }

            let (data, status) = try await get("get", [
                ("track_name", title), ("artist_name", artist), ("album_name", album),
                ("duration", String(Int(duration.rounded()))),
            ])
            switch status {
            case 200:
                let result = Self.result(from: try JSONDecoder().decode(LRCLIBRecord.self, from: data))
                guard result == .notFound else { return result }
                return try await search(title: title, artist: artist, duration: duration)
            case 404:
                return try await search(title: title, artist: artist, duration: duration)
            default:
                NSLog("[Lyrical] LRCLIB /get returned %d", status)
                return .failed
            }
        } catch {
            NSLog("[Lyrical] LRCLIB lookup failed: %@", "\(error)")
            return .failed
        }
    }

    private func search(title: String, artist: String, duration: TimeInterval) async throws -> LyricsResult {
        let (data, status) = try await get("search", [
            ("track_name", TitleNormalizer.normalize(title)), ("artist_name", artist),
        ])
        guard status == 200 else { return status == 404 ? .notFound : .failed }

        let records = try JSONDecoder().decode([LRCLIBRecord].self, from: data)
        guard let best = Self.bestMatch(records, duration: duration) else { return .notFound }
        return Self.result(from: best)
    }

    static func result(from record: LRCLIBRecord) -> LyricsResult {
        if record.instrumental == true { return .instrumental }
        if let synced = record.syncedLyrics {
            let lines = LRCParser.parse(synced)
            if lines.contains(where: { !$0.isGap }) { return .synced(lines) }
        }
        if let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
            return .plain(plain)
        }
        return .notFound
    }

    /// Within ±3 s of the track (any duration when ours is unknown), synced
    /// before plain, then closest duration.
    static func bestMatch(_ records: [LRCLIBRecord], duration: TimeInterval) -> LRCLIBRecord? {
        func delta(_ record: LRCLIBRecord) -> TimeInterval {
            guard duration > 0, let d = record.duration else { return 0 }
            return abs(d - duration)
        }
        let candidates = records.filter { record in
            guard duration > 0 else { return true }
            guard record.duration != nil else { return false }
            return delta(record) <= durationTolerance
        }
        return candidates.min { a, b in
            if a.hasSynced != b.hasSynced { return a.hasSynced }
            return delta(a) < delta(b)
        }
    }

    private func get(_ endpoint: String, _ query: [(String, String)]) async throws -> (Data, Int) {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(endpoint),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents leaves "+" alone, and servers decode a bare "+" as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
