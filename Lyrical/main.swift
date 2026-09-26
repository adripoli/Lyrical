//
//  main.swift
//  Lyrical
//
//  Entry point. Configured as an "accessory" (agent) app: no Dock icon, no menu
//  bar of its own — it lives in the status bar and paints the desktop.
//

import Cocoa

// Program start is already on the main thread; assert main-actor isolation so
// we can construct the @MainActor AppDelegate and drive NSApplication.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
