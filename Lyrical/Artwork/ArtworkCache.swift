//
//  ArtworkCache.swift
//  Lyrical
//
//  Two-tier cache for cover images, keyed by the CDN URL's content hash rather
//  than the track id — every track on an album shares one artwork URL, so this
//  is one download per ALBUM instead of one per track. Memory tier is a tiny
//  NSCache (the visible art is one image); disk tier is a flat LRU directory
//  trimmed by file count and total bytes.
//

import AppKit

actor ArtworkCache {

    /// ~/Library/Caches/com.lyrical.app/artwork/ — unsandboxed, so this is the real one.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.lyrical.app/artwork", isDirectory: true)
    }

    private let directory: URL
    private let maxFiles: Int
    private let maxBytes: Int
    private let memory = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default

    init(directory: URL, maxFiles: Int = 300, maxBytes: Int = 50 * 1024 * 1024) {
        self.directory = directory
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
        memory.countLimit = 12
        // No trim() here: an actor init can't await, and ArtworkStore already runs
        // one immediately on launch. Keeps tests free of a racing background task.
    }

    // MARK: - Keys

    /// Content hash from a CDN URL: the last path component, reduced to `[A-Za-z0-9]`.
    /// Deriving the key and sanitizing it against path traversal are the same step,
    /// so there is no way to reach a filename that escapes the cache directory.
    nonisolated static func hash(from url: URL) -> String? {
        let cleaned = url.lastPathComponent.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard !cleaned.isEmpty, cleaned.count <= 128 else { return nil }
        return String(cleaned)
    }

    /// Strict decode: garbage or a half-written file yields nil rather than an
    /// NSImage that only blows up later at draw time.
    nonisolated static func decode(_ data: Data) -> NSImage? {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            return nil
        }
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Lookup

    func image(forHash hash: String) -> NSImage? {
        if let cached = memory.object(forKey: hash as NSString) { return cached }

        let file = fileURL(hash)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }

        guard let image = Self.decode(data) else {
            NSLog("[Lyrical] discarding undecodable artwork cache entry %@", hash)
            try? fileManager.removeItem(at: file)
            return nil
        }

        // LRU means least recently *used*, and APFS access times aren't dependable,
        // so a read explicitly bumps the modification date trim() sorts on.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)

        memory.setObject(image, forKey: hash as NSString)
        return image
    }

    func store(_ data: Data, forHash hash: String) {
        guard let image = Self.decode(data) else { return }

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL(hash), options: .atomic)
        } catch {
            NSLog("[Lyrical] artwork cache write failed for %@ (%@)", hash, "\(error)")
        }

        memory.setObject(image, forKey: hash as NSString)
    }

    // MARK: - Eviction

    /// Deletes oldest-first until both limits are satisfied. Cheap and idempotent —
    /// a no-op directory scan when the cache is already under budget.
    func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return }

        var entries = contents.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let date = values.contentModificationDate,
                  let size = values.fileSize
            else { return nil }
            return (url, date, size)
        }
        entries.sort { $0.date < $1.date }

        var count = entries.count
        var bytes = entries.reduce(0) { $0 + $1.size }

        for entry in entries where count > maxFiles || bytes > maxBytes {
            do {
                try fileManager.removeItem(at: entry.url)
                count -= 1
                bytes -= entry.size
            } catch {
                NSLog("[Lyrical] artwork cache evict failed (%@)", "\(error)")
            }
        }
    }

    private func fileURL(_ hash: String) -> URL {
        directory.appendingPathComponent(hash, isDirectory: false)
    }
}
