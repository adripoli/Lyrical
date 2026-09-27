//
//  ControlPanelWindow.swift
//  Lyrical
//
//  The clickable half of the overlay. A single window can't be both
//  click-through and click-capturing, so the controls live in their own
//  non-activating panel sitting one level ABOVE Finder's desktop icon window
//  (so clicks reach it) but still ~2 billion levels below any normal app window
//  (so Safari, Xcode and friends cover it completely).
//

import SwiftUI

final class ControlPanelWindow: NSPanel {
    static let height: CGFloat = 86

    private let hosting: ClickThroughHostingView<ControlBarView>

    init(screen: NSScreen, nowPlaying: NowPlayingStore, config: LyricalConfig) {
        hosting = ClickThroughHostingView(rootView: ControlBarView(nowPlaying: nowPlaying, config: config))
        // The panel's frame is always set explicitly. Without this, every
        // progress redraw re-measures the bar's min, ideal and max sizes and
        // re-solves the window's Auto Layout constraints for nothing.
        hosting.sizingOptions = []

        super.init(contentRect: Self.frame(in: screen, config: config),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        level = Self.level(for: config)
        ignoresMouseEvents = false
        // Insurance for the hover reveals — SwiftUI's .onHover tracking areas are
        // .activeAlways so they don't need this, but it costs nothing.
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        canHide = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition(to screen: NSScreen, config: LyricalConfig) {
        setFrame(Self.frame(in: screen, config: config), display: true)
    }

    func apply(config: LyricalConfig) {
        level = Self.level(for: config)
        hosting.rootView.config = config
    }

    /// Whether anyone can see the bar. While not, its progress stops ticking.
    func setLive(_ live: Bool) {
        guard hosting.rootView.isLive != live else { return }
        hosting.rootView.isLive = live
    }

    static func frame(in screen: NSScreen, config: LyricalConfig) -> NSRect {
        let visible = screen.visibleFrame
        let width = min(CGFloat(config.controlBarWidth), visible.width - 80)
        return NSRect(
            x: screen.frame.midX - width / 2,
            // visibleFrame so the bar clears the Dock rather than hiding behind it.
            y: visible.minY + CGFloat(config.controlBarBottomInset),
            width: width,
            height: height
        )
    }

    private static func level(for config: LyricalConfig) -> NSWindow.Level {
        switch config.controlPanelLevel {
        case .aboveIcons:
            return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case .belowNormal:
            return NSWindow.Level(rawValue: -1)
        }
    }
}
