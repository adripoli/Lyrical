//
//  NowPlayingParser.swift
//  Lyrical
//
//  Turns the raw AppleScript reply into a NowPlayingSnapshot. Split in two: a
//  thin descriptor-flattening layer that needs a live Apple Event, and a pure
//  [String?] -> snapshot core that doesn't, so every interesting rule (the
//  millisecond duration, locale-proof number parsing, artwork URL shapes) is
//  unit-testable without Spotify running.
//

import Foundation

enum NowPlayingParser {

    /// Flattens the script's list result into 8 optional strings, in script order.
    /// A non-list reply (shouldn't happen, but AppleScript is AppleScript) coerces
    /// or yields an empty array, which the caller reads as a malformed response.
    static func fields(from descriptor: NSAppleEventDescriptor) -> [String?] {
        let list = descriptor.descriptorType == typeAEList
            ? descriptor
            : descriptor.coerce(toDescriptorType: typeAEList)

        guard let list, list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).map { list.atIndex($0)?.stringValue }
    }

    /// The testable core. Order: state, id, name, artist, album, durationMs,
    /// positionSec, artworkURL.
    static func snapshot(fields: [String?]) -> NowPlayingSnapshot? {
        guard fields.count >= 8 else { return nil }

        let state = playerState(fields[0])
        let position = max(number(fields[6]) ?? 0, 0)

        // Spotify reports `duration` in MILLISECONDS despite its dictionary saying
        // seconds. Everything downstream of here is seconds.
        let duration = max((number(fields[5]) ?? 0) / 1000, 0)

        let id = (fields[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            // Nothing loaded (or the `current track` access threw): still a valid
            // reading of state and position, just no track.
            return NowPlayingSnapshot(state: state, position: position, track: nil)
        }

        let track = TrackInfo(
            id: id,
            name: fields[2] ?? "",
            artist: fields[3] ?? "",
            album: fields[4] ?? "",
            duration: duration,
            artworkURL: normalizeArtworkURL(fields[7]),
            isAd: id.contains(":ad:")
        )
        return NowPlayingSnapshot(state: state, position: position, track: track)
    }

    /// The light poll's reply (state, id, positionSec) on top of `known`, the
    /// track the last full poll returned. nil means the full poll is needed:
    /// the track changed, nothing is known yet, or the reply made no sense.
    static func snapshot(light fields: [String?], known: TrackInfo?) -> NowPlayingSnapshot? {
        guard fields.count >= 3 else { return nil }
        let id = (fields[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let track: TrackInfo?
        if id.isEmpty {
            track = nil
        } else if let known, known.id == id {
            track = known
        } else {
            return nil
        }
        return NowPlayingSnapshot(state: playerState(fields[0]),
                                  position: max(number(fields[2]) ?? 0, 0),
                                  track: track)
    }

    /// Whether a fully polled track can stand in for its id on later light
    /// polls. One Spotify is still loading has no name yet, and must be polled
    /// in full again so its details arrive as soon as Spotify has them.
    static func isWorthRemembering(_ track: TrackInfo) -> Bool {
        !track.name.isEmpty
    }

    /// "spotify:image:<hash>" -> "https://i.scdn.co/image/<hash>"; https passes
    /// through; empty or unrecognized (local files, podcasts) -> nil.
    static func normalizeArtworkURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let imagePrefix = "spotify:image:"
        if trimmed.hasPrefix(imagePrefix) {
            let hash = String(trimmed.dropFirst(imagePrefix.count))
            guard !hash.isEmpty else { return nil }
            return URL(string: "https://i.scdn.co/image/\(hash)")
        }

        let lower = trimmed.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return nil }
        return URL(string: trimmed)
    }

    // MARK: - Scalars

    private static func playerState(_ raw: String?) -> PlayerState {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PlayerState(rawValue: text) ?? .stopped
    }

    /// `Double(String)` is locale-independent by definition; a NumberFormatter here
    /// would break on any machine with a comma decimal separator. AppleScript's own
    /// `as text` coercion, on the other hand, can hand back "12,437" on such a
    /// machine — hence the one retry, which is not a thousands-separator hazard
    /// because AppleScript never groups digits.
    private static func number(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(text) ?? Double(text.replacingOccurrences(of: ",", with: "."))
    }
}
