//
//  SpotifyBridgeScriptTests.swift
//  LyricalTests
//
//  NowPlayingParserTests exercises parsing from a stub descriptor, which never
//  actually compiles the embedded AppleScript. That gap let a real bug ship:
//  the poll script's `set st to ...` failed to compile because "st" collides
//  with a reserved token in AppleScript's own core terminology — reproducible
//  with zero apps targeted at all (`osascript -e 'set st to 5'` fails the same
//  way). Every poll silently failed, which looked exactly like "Spotify isn't
//  running" no matter what Spotify was actually doing. These tests compile the
//  real script source so a reserved-word collision fails the build, not a demo.
//

import XCTest
@testable import Lyrical

final class SpotifyBridgeScriptTests: XCTestCase {

    /// Compiling `tell application id "com.spotify.client"` resolves terms
    /// against Spotify's own dictionary, which needs the app installed (not
    /// necessarily running). Skip cleanly where that's not true rather than
    /// failing the whole suite in an environment without Spotify.
    private func requireSpotifyInstalled() throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyBridge.bundleID) != nil else {
            throw XCTSkip("Spotify isn't installed on this machine — skipping AppleScript compilation checks.")
        }
    }

    func testEveryScriptCompiles() throws {
        try requireSpotifyInstalled()
        let bridge = SpotifyBridge()

        for kind in SpotifyBridge.Script.allCases {
            let source = bridge.source(for: kind)
            guard let script = NSAppleScript(source: source) else {
                XCTFail("\(kind): could not construct NSAppleScript")
                continue
            }
            var error: NSDictionary?
            let ok = script.compileAndReturnError(&error)
            XCTAssertTrue(ok, "\(kind) failed to compile: \(error?.description ?? "unknown error")")
        }
    }
}
