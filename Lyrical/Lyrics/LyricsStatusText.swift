//
//  LyricsStatusText.swift
//  Lyrical
//
//  The words the title card and the menu use for each lyrics state, kept in
//  one place so the two never disagree.
//

enum LyricsStatusText {
    static func titleCard(for state: LyricsState) -> String? {
        switch state {
        case .idle, .loaded(.synced): return nil
        case .loading: return "Loading lyrics…"
        case .advertisement: return "Advertisement"
        case .loaded(.plain): return "Plain lyrics only"
        case .loaded(.instrumental): return "♪ Instrumental"
        case .loaded(.notFound): return "No lyrics found"
        case .loaded(.failed): return "Couldn't reach LRCLIB"
        }
    }

    static func menu(for state: LyricsState) -> String {
        switch state {
        case .idle: return "No track"
        case .loading: return "Loading…"
        case .advertisement: return "Advertisement"
        case .loaded(.synced): return "Synced lyrics · LRCLIB"
        case .loaded(.plain): return "Plain lyrics only"
        case .loaded(.instrumental): return "Instrumental"
        case .loaded(.notFound): return "No lyrics found"
        case .loaded(.failed): return "Couldn't reach LRCLIB"
        }
    }
}
