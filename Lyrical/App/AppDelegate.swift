//
//  AppDelegate.swift
//  Lyrical
//

import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit-test bundle is host-based: without this, `xcodebuild test`
        // would spawn a real app that takes over the actual desktop.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        ConfigStore.shared.load()
    }
}
