//
//  ArtworkStore.swift
//  Lyrical
//
//  Owns what the wallpaper should currently be showing. Keeps the views free of
//  fetching, caching and staleness concerns: they read `presentation` and, for
//  the expensive blurred backdrop, await `backdrop(hash:size:)`.
//

import AppKit

enum ArtworkPresentation: Equatable {
    case none
    case fallback(seed: String)
    case art(hash: String, cover: NSImage)
}

@MainActor
@Observable
final class ArtworkStore {
    private(set) var presentation: ArtworkPresentation = .none

    private let config: ConfigStore
    private let cache: ArtworkCache
    private let provider: ArtworkProvider

    @ObservationIgnored private var currentTrackID: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var trimTask: Task<Void, Never>?

    init(config: ConfigStore) {
        self.config = config
        let cache = ArtworkCache(directory: ArtworkCache.defaultDirectory)
        self.cache = cache
        self.provider = ArtworkProvider(cache: cache)

        startTrimming()
    }

    /// Cancels the in-flight load and the hourly cache trim. Call from app teardown.
    func stop() {
        loadTask?.cancel()
        loadTask = nil
        trimTask?.cancel()
        trimTask = nil
    }

    // MARK: - Track changes

    func setTrack(_ track: TrackInfo?) {
        // nil only ever means "Spotify quit" — pausing keeps the last art up, and
        // that's the caller's call to make, not ours.
        guard let track else {
            currentTrackID = nil
            loadTask?.cancel()
            loadTask = nil
            if presentation != .none { presentation = .none }
            return
        }

        guard track.id != currentTrackID else { return }
        currentTrackID = track.id
        loadTask?.cancel()
        loadTask = nil

        let seed = Self.seed(for: track)
        guard let url = track.artworkURL, let hash = ArtworkCache.hash(from: url) else {
            presentation = .fallback(seed: seed)
            return
        }

        // The payoff of hashing the CDN URL instead of the track id: the next track
        // on the same album is already on screen, so there's nothing to do.
        if case .art(let showing, _) = presentation, showing == hash { return }

        // Leave whatever is on screen alone while the new cover loads — no flash to black.
        loadTask = Task { [weak self] in
            await self?.load(url: url, hash: hash, trackID: track.id, seed: seed)
        }
    }

    private func load(url: URL, hash: String, trackID: String, seed: String) async {
        do {
            let cover = try await provider.cover(for: url)
            // Staleness rejection: the user skipped past this track while it loaded.
            guard currentTrackID == trackID, !Task.isCancelled else { return }
            presentation = .art(hash: hash, cover: cover)
        } catch {
            guard currentTrackID == trackID, !Task.isCancelled else { return }
            NSLog("[Lyrical] artwork load failed for %@ (%@) — falling back", hash, "\(error)")
            presentation = .fallback(seed: seed)
        }
    }

    /// Album, not title, so every track on a record draws the same gradient and it
    /// reads as intentional. Ads are pinned to one seed rather than flickering.
    private static func seed(for track: TrackInfo) -> String {
        if track.isAd { return "advertisement" }
        return track.album.isEmpty ? track.name : track.album
    }

    // MARK: - Backdrop

    /// Memoized per (hash, size). Returns nil until ready; callers re-request via `.task(id:)`.
    func backdrop(hash: String, size: CGSize) async -> NSImage? {
        guard case .art(let showing, let cover) = presentation, showing == hash else { return nil }

        let settings = config.current
        return await provider.backdrop(forHash: hash, cover: cover, size: size,
                                       blurRadius: settings.backdropBlurRadius,
                                       dim: settings.backdropDim)
    }

    // MARK: - Housekeeping

    private func startTrimming() {
        trimTask = Task { [weak self, cache] in
            while !Task.isCancelled {
                await cache.trim()
                try? await Task.sleep(for: .seconds(3600))
                guard self != nil else { return }
            }
        }
    }
}
