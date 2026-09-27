//
//  LyricsWindow.swift
//  Lyrical
//
//  The wallpaper itself: a borderless, transparent, full-screen window pinned
//  to the desktop window level. That puts it above the real wallpaper and
//  below Finder's desktop icons. It ignores mouse events entirely, so icon
//  clicks, drag-select, right-click menus and drag-and-drop all still work.
//
//  The lock-screen variant looks the same, plus a clock. It lives in
//  LockScreenSpace, which is composited over the whole lock screen: nothing
//  can go between the lock screen's background and its clock and password
//  prompt, so matching the desktop means covering those. Touch ID and typing
//  the password still work, because this window never takes the keyboard.
//

import SwiftUI

enum LyricsSurface {
    case desktop
    case lockScreen
}

final class LyricsWindow: NSWindow {
    let surface: LyricsSurface
    private let hosting: NSHostingView<LyricsWallpaperView>

    init(screen: NSScreen, surface: LyricsSurface = .desktop, nowPlaying: NowPlayingStore,
         lyrics: LyricsStore, palette: PaletteStore, config: LyricalConfig) {
        self.surface = surface
        hosting = NSHostingView(rootView: LyricsWallpaperView(
            nowPlaying: nowPlaying, lyrics: lyrics, palette: palette,
            config: config, screenSize: screen.frame.size,
            showsClock: surface == .lockScreen))

        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)

        switch surface {
        case .desktop:
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        case .lockScreen:
            // Ordering inside the lock-screen space; the space itself is what
            // lifts the window over loginwindow.
            level = .screenSaver
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            canBecomeVisibleWithoutLogin = true
        }
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        canHide = false            // Cmd-H / "Hide Others" must not blank the wallpaper
        animationBehavior = .none
        isReleasedWhenClosed = false

        contentView = hosting
        // Full frame, not visibleFrame: the wallpaper runs under the menu bar and Dock.
        setFrame(screen.frame, display: false)
    }

    // Never take the keyboard: on the lock screen that's the password field's.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
        hosting.rootView.screenSize = screen.frame.size
    }

    func apply(config: LyricalConfig) {
        hosting.rootView.config = config
    }
}
