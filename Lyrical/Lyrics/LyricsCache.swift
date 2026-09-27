//
//  LyricsCache.swift
//  Lyrical
//
//  One small JSON file per Spotify track id. Found lyrics never expire;
//  "not found" does after a week, because LRCLIB is crowd-sourced and the
//  song may have been added since. Failures are never written at all.
//  Each entry also remembers whether real word timing has been looked for,
//  so it's looked for once per song, including songs cached before it was.
//

import Foundation

actor LyricsCache {

    /// ~/Library/Caches/com.lyrical.app/lyrics/
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.lyrical.app/lyrics", isDirectory: true)
    }

    static let notFoundLifetime: TimeInterval = 7 * 24 * 3600

    struct Entry: Codable, Equatable {
        var result: LyricsResult
        var storedAt: Date
        /// Optional so entries written before it existed still decode (as false).
        var wordTimingChecked: Bool?
    }

    private let directory: URL
    private let now: @Sendable () -> Date

    init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    func result(for trackID: String) -> LyricsResult? {
        entry(for: trackID)?.result
    }

    func entry(for trackID: String) -> Entry? {
        let url = fileURL(trackID)
        guard let data = try? Data(contentsOf: url) else { return nil }

        guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            NSLog("[Lyrical] discarding unreadable lyrics cache entry %@", url.lastPathComponent)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if entry.result == .notFound, now().timeIntervalSince(entry.storedAt) > Self.notFoundLifetime {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return entry
    }

    func store(_ result: LyricsResult, for trackID: String, wordTimingChecked: Bool = false) {
        guard result != .failed else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entry = Entry(result: result, storedAt: now(), wordTimingChecked: wordTimingChecked)
            let data = try JSONEncoder().encode(entry)
            try data.write(to: fileURL(trackID), options: .atomic)
        } catch {
            NSLog("[Lyrical] lyrics cache write failed (%@)", "\(error)")
        }
    }

    func remove(trackID: String) {
        try? FileManager.default.removeItem(at: fileURL(trackID))
    }

    /// A readable prefix plus a hash of the full id. The prefix is reduced to
    /// `[A-Za-z0-9_-]`, so the name can't escape the directory. The hash keeps
    /// ids that differ only in punctuation apart, and keeps local-file ids
    /// (which can be very long) under the filesystem's name limit.
    nonisolated static func fileName(for trackID: String) -> String {
        let safe = String(trackID.map { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "_"
        })
        return "\(safe.prefix(60))-\(String(StableHash.fnv1a(trackID), radix: 16)).json"
    }

    private func fileURL(_ trackID: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: trackID))
    }
}
