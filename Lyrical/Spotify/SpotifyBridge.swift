//
//  SpotifyBridge.swift
//  Lyrical
//
//  The only place in the app that speaks to Spotify. One serial queue owns every
//  NSAppleScript instance (they are not thread-safe), scripts are compiled once
//  and reused, and nothing is ever sent unless Spotify is already running — a
//  `tell application` block would otherwise LAUNCH it, which is not something a
//  wallpaper app should do to you.
//

import AppKit
import Foundation

final class SpotifyBridge: NowPlayingSource, @unchecked Sendable {

    static let bundleID = "com.spotify.client"

    /// Internal (not private) so LyricalTests can compile every script's
    /// source text directly — see SpotifyBridgeScriptTests.
    enum Script: Hashable, CaseIterable { case poll, playPause, next, previous }

    private let queue = DispatchQueue(label: "com.lyrical.applescript")

    /// Touched only on `queue`.
    private var compiled: [Script: NSAppleScript] = [:]

    // MARK: - Availability

    /// Cheap, local, and event-free: no Apple Event is sent to answer this.
    func availability() -> SpotifyAvailability {
        // Running check first: it's the once-a-second path, and it saves a
        // LaunchServices lookup in the common case.
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.bundleID
        }
        if running { return .running }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) == nil
            ? .notInstalled : .notRunning
    }

    // MARK: - Public API

    func snapshot() async throws -> NowPlayingSnapshot {
        try await onQueue { try self.pollSync() }
    }

    func send(_ command: TransportCommand) async throws {
        try await onQueue { try self.sendSync(command) }
    }

    // MARK: - Queue plumbing

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Work (queue only)

    private func pollSync() throws -> NowPlayingSnapshot {
        try requireRunning()
        let result = try execute(script(.poll))
        guard let snapshot = NowPlayingParser.snapshot(fields: NowPlayingParser.fields(from: result)) else {
            throw SpotifyError.malformedResponse
        }
        return snapshot
    }

    private func sendSync(_ command: TransportCommand) throws {
        try requireRunning()

        switch command {
        case .playPause:
            _ = try execute(script(.playPause))
        case .next:
            _ = try execute(script(.next))
        case .previous:
            _ = try execute(script(.previous))
        case .seek(let position):
            // Seeks are rare and user-initiated, so compiling per call is fine.
            // "%.3f" keeps the decimal separator a dot whatever the locale is.
            let seconds = String(format: "%.3f", max(position, 0))
            _ = try execute(try compile(wrap("set player position to \(seconds)")))
        }
    }

    private func requireRunning() throws {
        switch availability() {
        case .notInstalled: throw SpotifyError.notInstalled
        case .notRunning: throw SpotifyError.notRunning
        case .running: break
        }
    }

    private func execute(_ script: NSAppleScript) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { throw Self.mapError(error) }
        return result
    }

    private func script(_ kind: Script) throws -> NSAppleScript {
        if let cached = compiled[kind] { return cached }
        // Compiled lazily rather than in init: compilation resolves Spotify's
        // scripting terminology, so there is no point doing it on a machine that
        // has never had Spotify running. After the first call it is cached forever.
        let script = try compile(source(for: kind))
        compiled[kind] = script
        return script
    }

    private func compile(_ source: String) throws -> NSAppleScript {
        guard let script = NSAppleScript(source: source) else {
            throw SpotifyError.scriptError(code: 0, message: "could not create NSAppleScript")
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            throw Self.mapError(error)
        }
        return script
    }

    // MARK: - Sources

    /// `application id` rather than by name so macOS never shows the "Where is
    /// Spotify?" chooser; `with timeout` caps a wedged Spotify at 2s instead of
    /// AppleScript's 60s default.
    private func wrap(_ body: String) -> String {
        """
        with timeout of 2 seconds
          tell application id "\(Self.bundleID)"
            \(body)
          end tell
        end timeout
        """
    }

    func source(for kind: Script) -> String {
        switch kind {
        case .playPause: return wrap("playpause")
        case .next: return wrap("next track")
        case .previous: return wrap("previous track")
        case .poll:
            // One round trip, returning a list rather than a delimited string —
            // track titles contain every delimiter you could pick. The inner try
            // around `artwork url` is load-bearing: it throws for local files and
            // some podcast episodes.
            return """
            with timeout of 2 seconds
              tell application id "\(Self.bundleID)"
                set playerState to (player state as text)
                set pos to 0
                try
                  set pos to player position
                end try
                try
                  set t to current track
                  set aurl to ""
                  try
                    set aurl to (artwork url of t) as text
                  end try
                  return {playerState, (id of t) as text, (name of t) as text, (artist of t) as text, (album of t) as text, (duration of t) as text, pos as text, aurl}
                on error
                  return {playerState, "", "", "", "", "0", pos as text, ""}
                end try
              end tell
            end timeout
            """
        }
    }

    // MARK: - Errors

    private static func mapError(_ info: NSDictionary?) -> SpotifyError {
        let code = (info?[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info?[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"

        switch code {
        case -1712: return .timedOut                // errAETimeout
        case -1743: return .permissionDenied        // errAEEventNotPermitted
        case -1744: return .permissionUndetermined  // errAEEventWouldRequireUserConsent
        case -600: return .notRunning               // procNotFound
        default: return .scriptError(code: code, message: message)
        }
    }
}
