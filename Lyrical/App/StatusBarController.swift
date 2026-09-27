//
//  StatusBarController.swift
//  Lyrical
//
//  The menu-bar icon and its menu, which is the only chrome Lyrical owns.
//  From it you can:
//  - see what's playing and whether lyrics were found
//  - hide the wallpaper or the lock-screen lyrics, and nudge the timing
//  - refetch lyrics and recover a denied automation grant
//  - edit the config, toggle the login item, or quit
//

import Cocoa
import ServiceManagement

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    static let offsetStep = 0.25
    static let offsetLimit = 10.0

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let config: ConfigStore
    private let nowPlaying: NowPlayingStore
    private let lyrics: LyricsStore
    private var configObserver: NSObjectProtocol?

    init(config: ConfigStore, nowPlaying: NowPlayingStore, lyrics: LyricsStore) {
        self.config = config
        self.nowPlaying = nowPlaying
        self.lyrics = lyrics
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "quote.bubble", accessibilityDescription: "Lyrical")

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        configObserver = NotificationCenter.default.addObserver(
            forName: .lyricalConfigDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncLoginItem() }
        }

        syncLoginItem()
        refresh()
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    func refresh() {
        statusItem.button?.appearsDisabled = nowPlaying.availability != .running
    }

    // MARK: - Formatting (pure, tested)

    static func formatOffset(_ offset: Double) -> String {
        "Timing: " + String(format: "%+.2f s", offset)
    }

    static func nudged(_ offset: Double, by delta: Double) -> Double {
        let rounded = ((offset + delta) * 100).rounded() / 100
        return min(max(rounded, -offsetLimit), offsetLimit)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        info(menu, infoTitle)
        let hasTrack = nowPlaying.availability == .running && lyrics.track != nil
        if hasTrack { info(menu, LyricsStatusText.menu(for: lyrics.state)) }
        menu.addItem(.separator())

        add(menu, "Show Lyrics", #selector(toggleWallpaper), state: config.current.showWallpaper ? .on : .off)
        add(menu, "Show on Lock Screen", #selector(toggleLockScreen),
            state: config.current.showOnLockScreen ? .on : .off).isEnabled = LockScreenSpace.shared != nil
        menu.addItem(displaysItem())

        menu.addItem(.separator())
        info(menu, Self.formatOffset(config.current.lyricsOffset))
        add(menu, "Lyrics Earlier", #selector(lyricsEarlier), key: "[")
        add(menu, "Lyrics Later", #selector(lyricsLater), key: "]")
        add(menu, "Reset Timing", #selector(resetTiming))
        add(menu, "Reload Lyrics", #selector(reloadLyrics), key: "l").isEnabled = hasTrack

        let canOpenSpotify = nowPlaying.availability == .notRunning
        let needsGrant = nowPlaying.permission == .denied || nowPlaying.permission == .undetermined
        if canOpenSpotify || needsGrant {
            menu.addItem(.separator())
            if canOpenSpotify { add(menu, "Open Spotify", #selector(openSpotify)) }
            if needsGrant { add(menu, "Grant Automation Access…", #selector(grantAutomationAccess)) }
        }

        menu.addItem(.separator())
        add(menu, "Reload Config", #selector(reloadConfig), key: "r")
        add(menu, "Open Config…", #selector(editConfig), key: "e")
        add(menu, "Start at Login", #selector(toggleStartAtLogin), state: isLoginItemEnabled ? .on : .off)

        menu.addItem(.separator())
        add(menu, "Quit Lyrical", #selector(quit), key: "q")
    }

    private var infoTitle: String {
        switch nowPlaying.availability {
        case .notInstalled: return "Spotify isn't installed"
        case .notRunning: return "Spotify isn't running"
        case .running:
            guard let track = nowPlaying.snapshot.track else { return "Nothing playing" }
            return track.artist.isEmpty ? "♪ \(track.name)" : "♪ \(track.name) — \(track.artist)"
        }
    }

    private func displaysItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let scope = config.current.displays
        add(submenu, "All Displays", #selector(useAllDisplays), state: scope == .all ? .on : .off)
        add(submenu, "Main Display Only", #selector(useMainDisplay), state: scope == .main ? .on : .off)
        item.submenu = submenu
        return item
    }

    private func info(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     key: String = "", state: NSControl.StateValue = .off) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = state
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    // Everything goes through the config file so a menu toggle survives a
    // restart and a hand edit + Reload Config behaves identically.
    @objc private func toggleWallpaper() { config.update { $0.showWallpaper.toggle() } }
    @objc private func toggleLockScreen() { config.update { $0.showOnLockScreen.toggle() } }
    @objc private func useAllDisplays() { config.update { $0.displays = .all } }
    @objc private func useMainDisplay() { config.update { $0.displays = .main } }
    @objc private func lyricsEarlier() { config.update { $0.lyricsOffset = Self.nudged($0.lyricsOffset, by: Self.offsetStep) } }
    @objc private func lyricsLater() { config.update { $0.lyricsOffset = Self.nudged($0.lyricsOffset, by: -Self.offsetStep) } }
    @objc private func resetTiming() { config.update { $0.lyricsOffset = LyricalConfig().lyricsOffset } }
    @objc private func reloadLyrics() { lyrics.reload() }
    @objc private func openSpotify() { nowPlaying.openSpotify() }
    @objc private func grantAutomationAccess() { AutomationPermission.openSystemSettings() }
    @objc private func reloadConfig() { config.reload() }
    @objc private func editConfig() { NSWorkspace.shared.open(config.url) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Login item

    private var isLoginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func toggleStartAtLogin() { config.update { $0.startAtLogin.toggle() } }

    private func syncLoginItem() {
        let wanted = config.current.startAtLogin
        guard wanted != isLoginItemEnabled else { return }
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Flaky when running out of DerivedData rather than /Applications. Never fatal.
            NSLog("[Lyrical] login item %@ failed: %@", wanted ? "register" : "unregister", "\(error)")
        }
    }
}
