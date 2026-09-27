//
//  LockScreenSpace.swift
//  Lyrical
//
//  The lock screen is drawn by loginwindow above every ordinary window level,
//  so no NSWindow.Level reaches it. SkyLight (the private WindowServer
//  framework) can: a space raised to the "notification center at screen lock"
//  absolute level is composited over the lock screen, and windows moved into
//  it go along. Same technique as github.com/Lakr233/SkyLightWindow (MIT).
//
//  Everything is resolved with dlsym at runtime, so a macOS that renames or
//  drops these symbols just loses the lock-screen lyrics instead of crashing.
//
//  That space is *always* on top, locked or not, so callers must keep their
//  windows ordered out whenever the screen is unlocked.
//

import AppKit

@MainActor
final class LockScreenSpace {
    /// nil when SkyLight doesn't have the calls we need.
    static let shared = LockScreenSpace()

    /// kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock: above the lock
    /// screen (300), below boot progress and VoiceOver.
    private static let absoluteLevel: Int32 = 400

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let connection: Int32
    private let space: Int32
    private let addWindows: SpaceAddWindowsAndRemoveFromSpaces

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW) else {
            NSLog("[Lyrical] SkyLight unavailable — no lock-screen lyrics")
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionID.self),
              let spaceCreate = symbol("SLSSpaceCreate", as: SpaceCreate.self),
              let setAbsoluteLevel = symbol("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let showSpaces = symbol("SLSShowSpaces", as: ShowSpaces.self),
              let addWindows = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces",
                                      as: SpaceAddWindowsAndRemoveFromSpaces.self)
        else {
            NSLog("[Lyrical] SkyLight is missing a lock-screen call — no lock-screen lyrics")
            return nil
        }

        connection = mainConnectionID()
        space = spaceCreate(connection, 1, 0)
        self.addWindows = addWindows
        _ = setAbsoluteLevel(connection, space, Self.absoluteLevel)
        _ = showSpaces(connection, [space] as CFArray)
    }

    /// Moves the window into the lock-screen space. Idempotent, so it's safe
    /// to call every time the window is shown.
    func adopt(_ window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        // 7 = remove from every other space the window is in.
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }

    /// Whether the login window is currently covering this session.
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
