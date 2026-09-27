//
//  ArtworkBackdrop.swift
//  Lyrical
//
//  CoverWall's wallpaper, shared by both surfaces so they look identical: the
//  cover blurred and dimmed full-bleed, or a deterministic gradient when the
//  track has no artwork. The desktop adds the crisp centred cover on top; the
//  lock screen leaves it off and puts the lyrics there instead.
//

import SwiftUI

struct ArtworkBackdrop: View {
    let nowPlaying: NowPlayingStore
    let artwork: ArtworkStore
    var config: LyricalConfig
    var screenSize: CGSize
    var showsCover: Bool

    var body: some View {
        content
            // Identity is the hash / seed, not the NSImage: this is what makes
            // the transition a cross-dissolve, and it makes a track arriving
            // mid-fade retarget rather than queue another fade behind the first.
            .id(Self.identity(of: artwork.presentation))
            .transition(.opacity)
    }

    @ViewBuilder
    private var content: some View {
        switch artwork.presentation {
        case .none:
            Color.clear
        case .fallback(let seed):
            ZStack {
                FallbackGradient(seed: seed)
                if showsCover { fallbackCover }
            }
        case .art(let hash, let cover):
            ArtLayer(artwork: artwork, hash: hash, cover: cover, config: config,
                     screenSize: screenSize, showsCover: showsCover)
        }
    }

    static func identity(of presentation: ArtworkPresentation) -> String {
        switch presentation {
        case .none: return "none"
        case .fallback(let seed): return "fallback:\(seed)"
        case .art(let hash, _): return "art:\(hash)"
        }
    }

    /// Local files, most podcasts and ads land here. Deliberate-looking, not an
    /// error state.
    private var fallbackCover: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note")
                .font(.system(size: 96, weight: .thin))
                .foregroundStyle(.white.opacity(0.55))

            if let track = nowPlaying.snapshot.track {
                VStack(spacing: 4) {
                    Text(track.name)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(track.artist)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}

// MARK: - Gradient

/// The deterministic two-hue wash, both as the no-artwork state and as the
/// placeholder while a backdrop renders.
private struct FallbackGradient: View {
    let seed: String

    var body: some View {
        let colors = ArtworkRenderer.fallbackColors(seed: seed)
        LinearGradient(
            colors: [Color(nsColor: colors.0), Color(nsColor: colors.1)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Art

/// Blurred full-bleed backdrop, plus the crisp centred cover on the desktop.
/// Owns the async backdrop fetch, so a track change tears this whole subtree
/// down and starts clean.
private struct ArtLayer: View {
    let artwork: ArtworkStore
    let hash: String
    let cover: NSImage
    let config: LyricalConfig
    let screenSize: CGSize
    let showsCover: Bool

    @State private var backdrop: NSImage?

    /// Re-render the backdrop on a new track, a resolution change, or a config
    /// hot-reload that touches the blur.
    private struct RenderKey: Equatable {
        var hash: String
        var size: CGSize
        var blurRadius: Double
        var dim: Double
    }

    private var renderKey: RenderKey {
        RenderKey(hash: hash, size: screenSize,
                  blurRadius: config.backdropBlurRadius, dim: config.backdropDim)
    }

    var body: some View {
        ZStack {
            if let backdrop {
                Image(nsImage: backdrop)
                    .resizable()
                    .scaledToFill()
                    .frame(width: screenSize.width, height: screenSize.height)
                    .clipped()
            } else {
                // Never black while the blur renders — a flash of empty screen
                // reads as a crash, a gradient reads as loading.
                FallbackGradient(seed: hash)
            }

            if showsCover {
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: screenSize.height * min(max(config.coverHeightFraction, 0.1), 1))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
            }
        }
        .task(id: renderKey) { await loadBackdrop() }
    }

    /// `backdrop(hash:size:)` returns nil while the store is still catching up to
    /// this hash, which is a real (if brief) race on a fast skip. Two retries, then
    /// leave the gradient up.
    private func loadBackdrop() async {
        for attempt in 0..<3 {
            if let image = await artwork.backdrop(hash: hash, size: screenSize) {
                backdrop = image
                return
            }
            guard attempt < 2, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
        NSLog("[Lyrical] backdrop unavailable for %@ after 3 attempts", hash)
    }
}
