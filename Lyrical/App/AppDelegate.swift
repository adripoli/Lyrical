//
//  AppDelegate.swift
//  Lyrical
//
//  Builds the stores and forwards NowPlayingStore's changes into
//  LyricsStore and PaletteStore. The observation loop below is the only
//  place the three meet.
//

import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var nowPlaying: NowPlayingStore?
    private var lyrics: LyricsStore?
    private var palette: PaletteStore?
    private var overlays: OverlayManager?
    private var statusBar: StatusBarController?
    private var configObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit-test bundle is host-based: without this, `xcodebuild test`
        // would spawn a real app that takes over the actual desktop.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            NSLog("[Lyrical] running under XCTest — skipping overlays and polling")
            return
        }

        let config = ConfigStore.shared
        config.load()

        let isMock = ProcessInfo.processInfo.environment["LYRICAL_MOCK"] == "1"
        let provider: LyricsProviding = isMock
            ? MockLyricsProvider()
            : CachedLyricsProvider(client: LRCLIBClient(),
                                   cache: LyricsCache(directory: LyricsCache.defaultDirectory),
                                   wordTiming: NetEaseClient(),
                                   isWordTimingEnabled: { await config.current.lookUpWordTiming })

        let nowPlaying = NowPlayingStore(config: config)
        let lyrics = LyricsStore(provider: provider, offset: { config.current.lyricsOffset })
        let palette = PaletteStore(config: config)
        let overlays = OverlayManager(config: config, nowPlaying: nowPlaying, lyrics: lyrics, palette: palette)

        self.nowPlaying = nowPlaying
        self.lyrics = lyrics
        self.palette = palette
        self.overlays = overlays
        self.statusBar = StatusBarController(config: config, nowPlaying: nowPlaying, lyrics: lyrics)

        overlays.start()
        nowPlaying.start()

        sync()
        observeNowPlaying()

        configObserver = NotificationCenter.default.addObserver(
            forName: .lyricalConfigDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configDidChange() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying?.stop()
        lyrics?.stop()
        palette?.stop()
        overlays?.stop()
    }

    // MARK: - Now playing -> lyrics + palette

    /// `withObservationTracking` is one-shot: re-arm from inside onChange or
    /// the wallpaper updates exactly once.
    private func observeNowPlaying() {
        guard let nowPlaying else { return }

        withObservationTracking {
            _ = nowPlaying.snapshot.track?.id
            _ = nowPlaying.availability
            _ = nowPlaying.permission
            _ = nowPlaying.clock
        } onChange: { [weak self] in
            // onChange runs *before* the new value is stored, so read it next turn.
            Task { @MainActor in
                guard let self else { return }
                self.sync()
                self.statusBar?.refresh()
                self.observeNowPlaying()
            }
        }
    }

    /// Only Spotify quitting clears the wallpaper. Pausing keeps the song up,
    /// with the carousel held on its line.
    private func sync() {
        guard let nowPlaying, let lyrics, let palette else { return }
        let track = nowPlaying.availability == .running ? nowPlaying.snapshot.track : nil
        lyrics.setTrack(track)
        palette.setTrack(track)
        lyrics.setClock(nowPlaying.clock)
    }

    private func configDidChange() {
        lyrics?.resync()   // lyricsOffset may have changed
        guard let nowPlaying, nowPlaying.availability == .running else { return }
        palette?.setTrack(nowPlaying.snapshot.track, force: true)   // brightness cap may have changed
    }
}
