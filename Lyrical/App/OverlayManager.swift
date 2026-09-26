//
//  OverlayManager.swift
//  Lyrical
//
//  Owns one LyricsWindow per display and keeps that set reconciled against
//  reality: display hot-plug, resolution changes, display sleep and fast user
//  switching. While the screens sleep, the Spotify poller is stopped.
//

import AppKit

@MainActor
final class OverlayManager {

    private let config: ConfigStore
    private let nowPlaying: NowPlayingStore
    private let lyrics: LyricsStore
    private let palette: PaletteStore

    private var windows: [CGDirectDisplayID: LyricsWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private var reconcileWork: DispatchWorkItem?
    private var isRunning = false
    private var isScreenAsleep = false

    init(config: ConfigStore, nowPlaying: NowPlayingStore, lyrics: LyricsStore, palette: PaletteStore) {
        self.config = config
        self.nowPlaying = nowPlaying
        self.lyrics = lyrics
        self.palette = palette
    }

    deinit {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            workspace.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        registerObservers()
        reconcile()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        reconcileWork?.cancel()
        reconcileWork = nil
        removeObservers()
        for window in windows.values { window.orderOut(nil) }
        windows.removeAll()
    }

    func applyConfig() {
        let current = config.current
        for window in windows.values { window.apply(config: current) }
        reconcile()
    }

    // MARK: - Reconciliation

    private func reconcile() {
        guard isRunning else { return }

        let current = config.current
        let screens = NSScreen.screens
        let wanted = displayIDs(for: current.displays, in: screens)
        let byID = Dictionary(uniqueKeysWithValues: screens.compactMap { screen in
            displayID(of: screen).map { ($0, screen) }
        })

        for (id, window) in windows where byID[id] == nil || !wanted.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
        }

        for id in wanted {
            guard let screen = byID[id] else { continue }
            if let existing = windows[id] {
                existing.reposition(to: screen)
            } else {
                windows[id] = LyricsWindow(screen: screen, nowPlaying: nowPlaying, lyrics: lyrics,
                                           palette: palette, config: current)
            }
        }

        applyVisibility()
        NSLog("[Lyrical] reconciled windows for %d display(s)", windows.count)
    }

    /// Screen-parameter notifications arrive in bursts; only the last matters.
    private func scheduleReconcile() {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func applyVisibility() {
        let visible = config.current.showWallpaper
        for window in windows.values {
            if visible { window.orderFrontRegardless() } else { window.orderOut(nil) }
        }
        // Occlusion tracking isn't reliable at the desktop window level on
        // macOS 26 (see CoverWall), so polling is gated on visibility and
        // display sleep only.
        nowPlaying.setActive(!isScreenAsleep && visible && !windows.isEmpty)
    }

    // MARK: - Observers

    private func registerObservers() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconcile() }
        })

        observers.append(center.addObserver(
            forName: .lyricalConfigDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyConfig() }
        })

        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleSleep() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            })
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            workspace.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handleSleep() {
        isScreenAsleep = true
        nowPlaying.setActive(false)
    }

    private func handleWake() {
        isScreenAsleep = false
        reconcile()               // displays can come back with different geometry
        nowPlaying.refreshNow()
    }

    // MARK: - Screens

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func displayIDs(for scope: DisplayScope, in screens: [NSScreen]) -> Set<CGDirectDisplayID> {
        switch scope {
        case .all:
            return Set(screens.compactMap(displayID(of:)))
        case .main:
            guard let main = NSScreen.main, let id = displayID(of: main) else { return [] }
            return [id]
        }
    }
}
