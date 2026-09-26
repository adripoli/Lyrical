//
//  Config.swift
//  Lyrical
//
//  The editable model behind the wallpaper. Everything the user customizes
//  lives in ~/.config/lyrical/config.json and decodes into these types. A
//  partial, stale or hand-mangled file must never break launch, so decoding is
//  per-key with defaults and a throw falls back wholesale. Range clamping
//  happens where values are used (CarouselMetrics, NowPlayingStore), not here,
//  so the file round-trips exactly what the user typed.
//

import Foundation

// MARK: - Model

enum DisplayScope: String, Codable { case all, main }
enum FontDesignOption: String, Codable { case standard = "default", rounded, serif }
enum TextAlignmentOption: String, Codable { case center, leading }

struct LyricalConfig: Codable, Equatable {
    var displays: DisplayScope = .all
    var showWallpaper: Bool = true
    var startAtLogin: Bool = true
    var pollIntervalPlaying: Double = 1.0
    var pollIntervalPaused: Double = 5.0
    var crossfadeDuration: Double = 0.5
    var lyricsOffset: Double = 0.25          // seconds; positive shows lines earlier
    var fontSizeFraction: Double = 0.045     // of screen height
    var fontDesign: FontDesignOption = .standard
    var textAlignment: TextAlignmentOption = .center
    var columnWidthFraction: Double = 0.6    // of screen width
    var anchorYFraction: Double = 0.5        // from the top
    var blurInactive: Bool = true
    var backdropBrightnessCap: Double = 0.35 // 0…1

    init() {}

    enum CodingKeys: String, CodingKey {
        case displays, showWallpaper, startAtLogin, pollIntervalPlaying, pollIntervalPaused
        case crossfadeDuration, lyricsOffset, fontSizeFraction, fontDesign, textAlignment
        case columnWidthFraction, anchorYFraction, blurInactive, backdropBrightnessCap
    }

    /// Per-key decoding so a partial file (or one written by an older/newer
    /// version) still yields a usable config instead of throwing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LyricalConfig()

        displays              = try c.decodeIfPresent(DisplayScope.self, forKey: .displays) ?? d.displays
        showWallpaper         = try c.decodeIfPresent(Bool.self, forKey: .showWallpaper) ?? d.showWallpaper
        startAtLogin          = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? d.startAtLogin
        pollIntervalPlaying   = try c.decodeIfPresent(Double.self, forKey: .pollIntervalPlaying) ?? d.pollIntervalPlaying
        pollIntervalPaused    = try c.decodeIfPresent(Double.self, forKey: .pollIntervalPaused) ?? d.pollIntervalPaused
        crossfadeDuration     = try c.decodeIfPresent(Double.self, forKey: .crossfadeDuration) ?? d.crossfadeDuration
        lyricsOffset          = try c.decodeIfPresent(Double.self, forKey: .lyricsOffset) ?? d.lyricsOffset
        fontSizeFraction      = try c.decodeIfPresent(Double.self, forKey: .fontSizeFraction) ?? d.fontSizeFraction
        fontDesign            = try c.decodeIfPresent(FontDesignOption.self, forKey: .fontDesign) ?? d.fontDesign
        textAlignment         = try c.decodeIfPresent(TextAlignmentOption.self, forKey: .textAlignment) ?? d.textAlignment
        columnWidthFraction   = try c.decodeIfPresent(Double.self, forKey: .columnWidthFraction) ?? d.columnWidthFraction
        anchorYFraction       = try c.decodeIfPresent(Double.self, forKey: .anchorYFraction) ?? d.anchorYFraction
        blurInactive          = try c.decodeIfPresent(Bool.self, forKey: .blurInactive) ?? d.blurInactive
        backdropBrightnessCap = try c.decodeIfPresent(Double.self, forKey: .backdropBrightnessCap) ?? d.backdropBrightnessCap
    }
}

// MARK: - Store

@MainActor
final class ConfigStore {
    static let shared = ConfigStore(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrical/config.json"))

    let url: URL
    private(set) var current = LyricalConfig()

    init(url: URL) {
        self.url = url
    }

    /// Reads the on-disk config, seeding it from the bundled default on first run.
    func load() {
        seedIfNeeded()
        do {
            let data = try Data(contentsOf: url)
            current = try JSONDecoder().decode(LyricalConfig.self, from: data)
        } catch {
            NSLog("[Lyrical] config load failed (%@) — using defaults", "\(error)")
            current = LyricalConfig()
        }
    }

    /// Re-reads from disk and tells everyone holding derived state to rebuild.
    func reload() {
        load()
        NotificationCenter.default.post(name: .lyricalConfigDidChange, object: self)
    }

    /// Mutate, persist, broadcast. The menu bar writes the same file the user edits
    /// by hand, so a toggle flipped from the menu survives a restart — and everyone
    /// picks it up through the same notification a manual reload uses.
    func update(_ transform: (inout LyricalConfig) -> Void) {
        var updated = current
        transform(&updated)
        guard updated != current else { return }

        current = updated
        write()
        NotificationCenter.default.post(name: .lyricalConfigDidChange, object: self)
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(current).write(to: url, options: .atomic)
        } catch {
            NSLog("[Lyrical] config write failed (%@) — change is live but not saved", "\(error)")
        }
    }

    private func seedIfNeeded() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let bundled = Bundle.main.url(forResource: "config.default", withExtension: "json"),
           let data = try? Data(contentsOf: bundled) {
            try? data.write(to: url)
        } else if let data = try? JSONEncoder().encode(LyricalConfig()) {
            try? data.write(to: url)
        }
    }
}

extension Notification.Name {
    static let lyricalConfigDidChange = Notification.Name("lyricalConfigDidChange")
}
