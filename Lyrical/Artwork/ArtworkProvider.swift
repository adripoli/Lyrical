//
//  ArtworkProvider.swift
//  Lyrical
//
//  Fetch side of the artwork pipeline: cache lookup, and one network request
//  per content hash no matter how many callers ask at once, and memoized
//  backdrop rendering per (hash × screen size), so the desktop and lock-screen
//  windows on one display share a single blur. Everything here runs off the
//  main actor.
//

import AppKit

enum ArtworkError: Error, Equatable {
    case unusableURL
    case undecodable
    case badStatus(Int)
}

actor ArtworkProvider {

    private let cache: ArtworkCache
    private let session: URLSession
    private var inFlight: [String: Task<NSImage, Error>] = [:]
    private var backdrops: [(key: String, image: NSImage)] = []

    private static let backdropLimit = 6

    init(cache: ArtworkCache, session: URLSession = ArtworkProvider.makeSession()) {
        self.cache = cache
        self.session = session
    }

    /// We own caching (content-addressed, on disk), so URLSession's is dead weight.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    // MARK: - Cover

    func cover(for url: URL) async throws -> NSImage {
        guard let hash = ArtworkCache.hash(from: url) else { throw ArtworkError.unusableURL }

        if let cached = await cache.image(forHash: hash) { return cached }

        // Re-checked after the cache await: a request that started while we were
        // suspended must join that fetch rather than start a second one.
        if let existing = inFlight[hash] { return try await existing.value }

        let task = Task<NSImage, Error> { [cache, session] in
            let data = try await Self.fetch(url, session: session)
            guard let image = ArtworkCache.decode(data) else { throw ArtworkError.undecodable }
            await cache.store(data, forHash: hash)
            return image
        }
        inFlight[hash] = task

        // Awaiting a Task's value ignores the *waiter's* cancellation, so this only
        // fires once the fetch itself is really done — safe to clear the slot here.
        do {
            let image = try await task.value
            inFlight[hash] = nil
            return image
        } catch {
            inFlight[hash] = nil
            throw error
        }
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        do {
            return try await load(url, session: session)
        } catch let error as URLError where error.code != .cancelled {
            // Exactly one retry. A wallpaper is not worth a retry storm, and the
            // fallback gradient is a perfectly good outcome.
            NSLog("[Lyrical] artwork fetch failed (%@) — retrying once", error.localizedDescription)
            try await Task.sleep(for: .seconds(2))
            return try await load(url, session: session)
        }
    }

    private static func load(_ url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ArtworkError.badStatus(http.statusCode)
        }
        return data
    }

    // MARK: - Backdrop

    /// Memoized per (hash, size). Runs on the provider's executor, never the main one.
    func backdrop(forHash hash: String, cover: NSImage, size: CGSize,
                  blurRadius: CGFloat, dim: Double) async -> NSImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }

        // Blur and dim are part of the key so a config hot-reload actually produces
        // a new bitmap instead of serving the one rendered with the old settings.
        let key = "\(hash)@\(Int(size.width))x\(Int(size.height))#\(blurRadius)/\(dim)"
        if let index = backdrops.firstIndex(where: { $0.key == key }) {
            let hit = backdrops.remove(at: index)
            backdrops.append(hit)
            return hit.image
        }

        let image = ArtworkRenderer.blurred(cover, targetSize: size,
                                            blurRadius: blurRadius, dim: dim)

        backdrops.append((key, image))
        if backdrops.count > Self.backdropLimit { backdrops.removeFirst() }
        return image
    }
}
