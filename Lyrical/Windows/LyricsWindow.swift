//
//  LyricsWindow.swift
//  Lyrical
//
//  The wallpaper itself: a borderless, transparent, full-screen window pinned
//  to the desktop window level. That puts it above the real wallpaper and
//  below Finder's desktop icons. It ignores mouse events entirely, so icon
//  clicks, drag-select, right-click menus and drag-and-drop all still work.
//

import SwiftUI

final class LyricsWindow: NSWindow {
    private let hosting: NSHostingView<LyricsWallpaperView>

    init(screen: NSScreen, nowPlaying: NowPlayingStore, lyrics: LyricsStore,
         palette: PaletteStore, config: LyricalConfig) {
        hosting = NSHostingView(rootView: LyricsWallpaperView(
            nowPlaying: nowPlaying, lyrics: lyrics, palette: palette,
            config: config, screenSize: screen.frame.size))

        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        canHide = false            // Cmd-H / "Hide Others" must not blank the wallpaper
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        contentView = hosting
        // Full frame, not visibleFrame: the wallpaper runs under the menu bar and Dock.
        setFrame(screen.frame, display: false)
    }

    func reposition(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
        hosting.rootView.screenSize = screen.frame.size
    }

    func apply(config: LyricalConfig) {
        hosting.rootView.config = config
    }
}
