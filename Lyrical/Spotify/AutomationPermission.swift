//
//  AutomationPermission.swift
//  Lyrical
//
//  Reads the app's Apple Events authorisation for Spotify WITHOUT prompting, so
//  the UI can explain itself instead of silently doing nothing. The `false` at
//  the end of AEDeterminePermissionToAutomateTarget is `askUserIfNeeded` — that
//  is the whole trick; passing true here would pop the system dialog on every
//  status check.
//

import AppKit
import CoreServices
import Foundation

enum AutomationPermission {

    static func state() -> AutomationPermissionState {
        let target = NSAppleEventDescriptor(bundleIdentifier: SpotifyBridge.bundleID)
        guard let address = target.aeDesc else { return .targetMissing }

        // `aeDesc` points into `target`; keep it alive across the call.
        let status = withExtendedLifetime(target) {
            AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false)
        }

        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .undetermined
        case OSStatus(procNotFound): return .targetMissing
        default:
            NSLog("[Lyrical] automation permission check returned %d", status)
            return .undetermined
        }
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
