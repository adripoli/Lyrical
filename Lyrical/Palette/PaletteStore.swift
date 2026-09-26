//
//  PaletteStore.swift
//  Lyrical
//
//  Track → cover → palette, published for the backdrop. The old palette stays
//  up while a new cover loads (no flash to black), and consecutive tracks on
//  one album reuse the palette already on screen.
//

import AppKit
import Observation

@MainActor
@Observable
final class PaletteStore {
    private(set) var palette: Palette?

    @ObservationIgnored private let config: ConfigStore
    @ObservationIgnored private let cache: ArtworkCache
    @ObservationIgnored private let provider: ArtworkProvider
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

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        trimTask?.cancel()
        trimTask = nil
    }

    /// `force` re-extracts for the same track (after the brightness cap changes).
    func setTrack(_ track: TrackInfo?, force: Bool = false) {
        guard let track else {
            currentTrackID = nil
            loadTask?.cancel()
            loadTask = nil
            if palette != nil { palette = nil }
            return
        }
        guard force || track.id != currentTrackID else { return }
        currentTrackID = track.id
        loadTask?.cancel()
        loadTask = nil

        let cap = config.current.backdropBrightnessCap
        let seed = Self.seed(for: track)
        guard let url = track.artworkURL, let hash = ArtworkCache.hash(from: url) else {
            palette = .fallback(seed: seed, cap: cap)
            return
        }
        if !force, palette?.key == hash { return }

        loadTask = Task { [weak self, provider] in
            var result = Palette.fallback(seed: seed, cap: cap)
            do {
                let cover = try await provider.cover(for: url)
                if let cgImage = Self.cgImage(from: cover) {
                    result = await Task.detached(priority: .utility) {
                        PaletteExtractor.palette(from: cgImage, key: hash, brightnessCap: cap)
                    }.value
                }
            } catch {
                NSLog("[Lyrical] artwork load failed (%@) — fallback palette", "\(error)")
            }
            guard let self, !Task.isCancelled, self.currentTrackID == track.id else { return }
            self.palette = result
        }
    }

    /// Album, not title, so every track on a record shares one fallback palette.
    private static func seed(for track: TrackInfo) -> String {
        if track.isAd { return "advertisement" }
        return track.album.isEmpty ? track.name : track.album
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        for rep in image.representations {
            if let bitmap = rep as? NSBitmapImageRep, let cgImage = bitmap.cgImage { return cgImage }
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

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
