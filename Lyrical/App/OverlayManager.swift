//
//  OverlayManager.swift
//  Lyrical
//
//  Owns one album-cover LyricsWindow per display, plus CoverWall's clickable
//  progress-and-transport ControlPanelWindow, and keeps those reconciled
//  against reality: display hot-plug, resolution changes, display sleep and
//  fast user switching. While the screens sleep, the Spotify poller is stopped.
//
//  While the screen is locked it also owns a second set, with the lyrics and a
//  clock, on the lock screen. Those only exist between lock and unlock: their
//  space sits above everything, so a leftover one would float over the
//  unlocked desktop.
//

import AppKit

@MainActor
final class OverlayManager {

    private let config: ConfigStore
    private let nowPlaying: NowPlayingStore
    private let lyrics: LyricsStore
    private let artwork: ArtworkStore

    private var windows: [CGDirectDisplayID: LyricsWindow] = [:]
    private var lockScreenWindows: [CGDirectDisplayID: LyricsWindow] = [:]
    private var controlPanels: [CGDirectDisplayID: ControlPanelWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private var reconcileWork: DispatchWorkItem?
    private var isRunning = false
    private var isScreenAsleep = false
    private var isScreenLocked = false

    init(config: ConfigStore, nowPlaying: NowPlayingStore, lyrics: LyricsStore, artwork: ArtworkStore) {
        self.config = config
        self.nowPlaying = nowPlaying
        self.lyrics = lyrics
        self.artwork = artwork
    }

    deinit {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for observer in observers {
            center.removeObserver(observer)
            workspace.removeObserver(observer)
            distributed.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isScreenLocked = LockScreenSpace.isScreenLocked
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
        for window in lockScreenWindows.values { window.orderOut(nil) }
        for panel in controlPanels.values { panel.orderOut(nil) }
        windows.removeAll()
        lockScreenWindows.removeAll()
        controlPanels.removeAll()
    }

    func applyConfig() {
        let current = config.current
        for window in windows.values { window.apply(config: current) }
        for window in lockScreenWindows.values { window.apply(config: current) }
        for panel in controlPanels.values { panel.apply(config: current) }
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
                                           artwork: artwork, config: current)
            }
        }

        let wantedControls = current.showControls ? wanted : []
        for (id, panel) in controlPanels where byID[id] == nil || !wantedControls.contains(id) {
            panel.orderOut(nil)
            controlPanels[id] = nil
        }
        for id in wantedControls {
            guard let screen = byID[id] else { continue }
            if let existing = controlPanels[id] {
                existing.reposition(to: screen, config: current)
            } else {
                controlPanels[id] = ControlPanelWindow(screen: screen, nowPlaying: nowPlaying, config: current)
            }
        }

        let wantsLockScreen = isScreenLocked && current.showOnLockScreen && LockScreenSpace.shared != nil
        let wantedOnLockScreen = wantsLockScreen ? wanted : []
        let hadLockScreen = !lockScreenWindows.isEmpty
        for (id, window) in lockScreenWindows where byID[id] == nil || !wantedOnLockScreen.contains(id) {
            window.orderOut(nil)
            lockScreenWindows[id] = nil
        }
        if hadLockScreen && lockScreenWindows.isEmpty { releaseLockScreenMemory() }
        for id in wantedOnLockScreen {
            guard let screen = byID[id] else { continue }
            if let existing = lockScreenWindows[id] {
                existing.reposition(to: screen)
            } else {
                lockScreenWindows[id] = LyricsWindow(screen: screen, surface: .lockScreen, nowPlaying: nowPlaying,
                                                     lyrics: lyrics, artwork: artwork, config: current)
            }
        }

        applyVisibility()
        NSLog("[Lyrical] reconciled windows for %d display(s), %d on the lock screen",
              windows.count, lockScreenWindows.count)
    }

    /// Animated lyrics leave tens of megabytes of freed allocations (glyph
    /// bitmaps, render buffers) dirty in the malloc zones, which would stay
    /// charged to Lyrical until the next lock. Hand them back to the system
    /// once the lock-screen windows have finished tearing down.
    private func releaseLockScreenMemory() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
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
        // The bar is useless on the lock screen (it's under loginwindow), and
        // its level sits above the desktop icons, so keep it out while locked.
        let controlsVisible = !isScreenLocked
        for panel in controlPanels.values {
            if controlsVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
        // Adopt before ordering in, so the window never shows at its own
        // level over the desktop, even for a frame.
        for window in lockScreenWindows.values {
            LockScreenSpace.shared?.adopt(window)
            window.orderFrontRegardless()
        }
        // Occlusion tracking isn't reliable at the desktop window level on
        // macOS 26 (see CoverWall), so polling is gated on visibility and
        // display sleep only.
        let onDesktop = (visible && !windows.isEmpty) || (controlsVisible && !controlPanels.isEmpty)
        nowPlaying.setActive(!isScreenAsleep && (onDesktop || !lockScreenWindows.isEmpty))
        applyLiveness()
    }

    /// Stops the ticking and per-frame drawing wherever nobody can see it:
    /// everything while the displays sleep, and the desktop while the screen
    /// is locked. The music plays on, so none of this is implied by playback.
    private func applyLiveness() {
        let desktopLive = !isScreenAsleep && !isScreenLocked
        for window in windows.values { window.setLive(desktopLive) }
        for panel in controlPanels.values { panel.setLive(desktopLive) }
        for window in lockScreenWindows.values { window.setLive(!isScreenAsleep) }
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

        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreenLocked(locked) }
            })
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for observer in observers {
            center.removeObserver(observer)
            workspace.removeObserver(observer)
            distributed.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handleSleep() {
        isScreenAsleep = true
        nowPlaying.setActive(false)
        applyLiveness()
    }

    private func handleWake() {
        isScreenAsleep = false
        // A lock or unlock notification can go missing across sleep; the
        // session dictionary is the source of truth.
        isScreenLocked = LockScreenSpace.isScreenLocked
        reconcile()               // displays can come back with different geometry
        nowPlaying.refreshNow()
    }

    private func setScreenLocked(_ locked: Bool) {
        guard locked != isScreenLocked else { return }
        isScreenLocked = locked
        NSLog("[Lyrical] screen %@", locked ? "locked" : "unlocked")
        reconcile()
        if locked { nowPlaying.refreshNow() }
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
