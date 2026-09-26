//
//  LyricsStore.swift
//  Lyrical
//
//  What the wallpaper shows, and which line is lit. Fed by AppDelegate from
//  NowPlayingStore: `setTrack` on every track change, `setClock` on every
//  poll. Between polls a single task sleeps exactly until the next line's
//  boundary, so there is no per-frame work. Between lines, CPU is zero.
//

import Foundation
import Observation

enum LyricsMove: Equatable {
    /// Moved forward by a few lines: spring with the staggered wave.
    case advance
    /// Seek, skip or rewind: quick ease, no stagger.
    case jump
}

@MainActor
@Observable
final class LyricsStore {
    private(set) var state: LyricsState = .idle
    private(set) var activeIndex: Int?
    private(set) var lastMove: LyricsMove = .jump
    private(set) var track: TrackInfo?
    private(set) var isPlaying = false

    var lines: [LyricLine] {
        if case .loaded(.synced(let lines)) = state { return lines }
        return []
    }

    static let maxAdvanceLines = 3
    static let maxRetryDelay: TimeInterval = 300

    @ObservationIgnored private let provider: LyricsProviding
    @ObservationIgnored private let offset: @MainActor () -> TimeInterval
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let initialRetryDelay: TimeInterval
    @ObservationIgnored private var retryDelay: TimeInterval
    @ObservationIgnored private var clock = PlaybackClock()
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(provider: LyricsProviding,
         offset: @escaping @MainActor () -> TimeInterval,
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         retryDelay: TimeInterval = 5) {
        self.provider = provider
        self.offset = offset
        self.now = now
        self.initialRetryDelay = retryDelay
        self.retryDelay = retryDelay
    }

    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Inputs

    /// nil means "Spotify isn't running". The same id again is a no-op, which
    /// is what makes a 1 Hz call from the poller free.
    func setTrack(_ newTrack: TrackInfo?) {
        guard newTrack?.id != track?.id else { return }

        fetchTask?.cancel()
        fetchTask = nil
        track = newTrack
        retryDelay = initialRetryDelay
        setActiveIndex(nil, move: .jump)

        guard let newTrack else {
            state = .idle
            reschedule()
            return
        }
        if newTrack.isAd {
            state = .advertisement
            reschedule()
            return
        }
        state = .loading
        fetch(newTrack)
    }

    func setClock(_ newClock: PlaybackClock) {
        clock = newClock
        if isPlaying != newClock.isPlaying { isPlaying = newClock.isPlaying }
        resync()
    }

    /// Recompute the lit line from the clock and re-arm the boundary timer.
    /// Also the entry point after a config change (lyricsOffset).
    func resync() {
        let position = clock.position(at: now())
        let index = LyricsTimeline.activeIndex(in: lines, at: position, offset: offset())
        if index != activeIndex {
            setActiveIndex(index, move: Self.move(from: activeIndex, to: index))
        }
        reschedule()
    }

    func reload() {
        guard let track, !track.isAd else { return }
        retryDelay = initialRetryDelay
        state = .loading
        setActiveIndex(nil, move: .jump)
        fetch(track, invalidating: true)
    }

    static func move(from old: Int?, to new: Int?) -> LyricsMove {
        guard let new else { return .jump }
        let step = new - (old ?? -1)
        return (1...maxAdvanceLines).contains(step) ? .advance : .jump
    }

    // MARK: - Fetching

    private func fetch(_ track: TrackInfo, after delay: TimeInterval = 0, invalidating: Bool = false) {
        fetchTask?.cancel()
        let provider = self.provider
        fetchTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if invalidating { await provider.invalidate(trackID: track.id) }
            guard !Task.isCancelled else { return }
            let result = await provider.lyrics(for: track)
            guard !Task.isCancelled else { return }
            self?.apply(result, for: track)
        }
    }

    private func apply(_ result: LyricsResult, for fetched: TrackInfo) {
        // A late answer for a track we've already skipped past must never land.
        guard fetched.id == track?.id else { return }

        switch result {
        case .synced(let lines):
            state = .loaded(.synced(LyricsTimeline.withIntroGap(lines)))
        case .failed:
            state = .loaded(.failed)
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
            NSLog("[Lyrical] lyrics fetch failed; retrying in %.0fs", delay)
            fetch(fetched, after: delay)
        default:
            state = .loaded(result)
        }
        resync()
    }

    // MARK: - Boundary timer

    private func setActiveIndex(_ index: Int?, move: LyricsMove) {
        guard index != activeIndex else { return }
        lastMove = move          // set first: the view reads both in one pass
        activeIndex = index
    }

    private func reschedule() {
        tickTask?.cancel()
        tickTask = nil
        guard clock.isPlaying, !lines.isEmpty else { return }

        let position = clock.position(at: now())
        guard let boundary = LyricsTimeline.nextBoundary(in: lines, at: position, offset: offset()) else { return }
        // The clock stops at the track's end. A line stamped after that would
        // re-arm forever at a fixed distance, so don't schedule it at all.
        if clock.duration > 0, boundary > clock.duration { return }

        // A few ms past the boundary, so the re-check lands on the new line
        // rather than just before it.
        let delay = max(boundary - position, 0) + 0.005
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.resync()
        }
    }

    // MARK: - Test hooks

    func waitForPendingFetch() async {
        await fetchTask?.value
    }

    var hasPendingTick: Bool { tickTask != nil }
}
