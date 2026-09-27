//
//  NowPlayingStore.swift
//  Lyrical
//
//  Single source of truth for playback state, injected into the SwiftUI views.
//  Polls Spotify at 1 Hz while playing / 0.2 Hz while paused, not at all while
//  Spotify is quit, we're off screen, or automation is denied — and uses
//  Spotify's own PlaybackStateChanged notification as an edge trigger so track
//  changes land immediately without polling any harder.
//

import AppKit
import Foundation

@MainActor
@Observable
final class NowPlayingStore {
    private(set) var availability: SpotifyAvailability = .notRunning
    /// Its `position` is as of the last change the clock didn't predict; the
    /// live playhead is `clock` / `displayPosition`.
    private(set) var snapshot: NowPlayingSnapshot = .idle
    private(set) var clock = PlaybackClock()
    private(set) var permission: AutomationPermissionState = .undetermined
    private(set) var lastError: SpotifyError?

    /// `systemUptime` of the last poll whose position jumped more than the clock's
    /// 1.5s threshold — someone scrubbed inside Spotify or hit a media key. The UI
    /// reads this to snap the progress bar instead of animating to the new spot.
    private(set) var lastSeekDetectedAt: TimeInterval?

    /// Interpolated position for UI. Live between polls; the poll re-anchors the clock.
    var displayPosition: TimeInterval {
        clock.position(at: ProcessInfo.processInfo.systemUptime)
    }

    @ObservationIgnored private let config: ConfigStore
    @ObservationIgnored private let source: NowPlayingSource
    @ObservationIgnored private let isMock: Bool
    @ObservationIgnored private let permissionCheck: @Sendable () -> AutomationPermissionState
    @ObservationIgnored private let permissionTimeout: TimeInterval

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var distributedObserver: NSObjectProtocol?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var isPolling = false
    @ObservationIgnored private var consecutiveFailures = 0

    private static let permissionRecheckInterval: TimeInterval = 10
    private static let transportConfirmDelay: Duration = .milliseconds(250)

    init(config: ConfigStore,
         source: NowPlayingSource? = nil,
         permissionCheck: @escaping @Sendable () -> AutomationPermissionState = { AutomationPermission.state() },
         permissionTimeout: TimeInterval = 3) {
        self.config = config
        self.isMock = ProcessInfo.processInfo.environment["LYRICAL_MOCK"] == "1"
        self.source = source ?? (isMock ? MockNowPlayingSource() : SpotifyBridge())
        self.permissionCheck = permissionCheck
        self.permissionTimeout = permissionTimeout
        self.availability = self.source.availability()
    }

    deinit {
        // deinit can't hop to the main actor; the observer blocks only hold `self`
        // weakly and stop() is called from applicationWillTerminate anyway.
        pollTask?.cancel()
        permissionTask?.cancel()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true

        registerObservers()
        // Silent check — no dialog. `.undetermined` still polls: the first real
        // scripting call is the right moment for the system prompt to appear.
        // Run off the main thread with a timeout: AEDeterminePermissionToAutomateTarget
        // has been seen to block forever for Spotify, which froze launch before the
        // wallpaper window ever reached the screen. A reply from the first poll
        // settles the question anyway.
        if isMock {
            permission = .granted
        } else {
            checkPermissionInBackground()
        }
        availability = source.availability()

        NSLog("[Lyrical] now playing: availability=%@ permission=%@",
              "\(availability)", "\(permission)")

        updateScheduling()
        refreshNow()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        removeObservers()
        stopPolling()
        stopPermissionWatch()
    }

    /// Occlusion / hidden / display-sleep gating. False means "send no Apple Events".
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        updateScheduling()
        if active { refreshNow() }
    }

    func refreshNow() {
        if availability != .running { updateAvailability() }
        poll()
    }

    // MARK: - Transport

    func playPause() {
        guard canControl else { return }

        let uptime = ProcessInfo.processInfo.systemUptime
        let position = clock.position(at: uptime)
        let willPlay = snapshot.state != .playing

        send(.playPause)
        snapshot.state = willPlay ? .playing : .paused
        snapshot.position = position
        clock.reanchor(position: position, uptime: uptime,
                       isPlaying: willPlay, duration: clock.duration)
    }

    func next() {
        guard canControl, snapshot.track?.isAd != true else { return }
        send(.next)
        anchorAtTrackStart()
    }

    func previous() {
        guard canControl, snapshot.track?.isAd != true else { return }
        send(.previous)
        anchorAtTrackStart()
    }

    func seek(to position: TimeInterval) {
        guard canControl else { return }

        let clamped = min(max(position, 0), max(snapshot.track?.duration ?? 0, 0))
        send(.seek(clamped))
        snapshot.position = clamped
        clock.reanchor(position: clamped,
                       uptime: ProcessInfo.processInfo.systemUptime,
                       isPlaying: snapshot.state == .playing,
                       duration: clock.duration)
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyBridge.bundleID) else {
            NSLog("[Lyrical] openSpotify: Spotify is not installed")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { NSLog("[Lyrical] openSpotify failed: %@", "\(error)") }
        }
    }

    private var canControl: Bool {
        availability == .running && permission != .denied
    }

    /// Skips land at 0 in the overwhelmingly common case; the confirming poll
    /// 250ms later fixes it if Spotify disagreed.
    private func anchorAtTrackStart() {
        snapshot.position = 0
        clock.reanchor(position: 0,
                       uptime: ProcessInfo.processInfo.systemUptime,
                       isPlaying: true,
                       duration: clock.duration)
    }

    private func send(_ command: TransportCommand) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.source.send(command)
            } catch {
                self.handle(error)
            }
            try? await Task.sleep(for: Self.transportConfirmDelay)
            self.refreshNow()
        }
    }

    // MARK: - Polling

    private var canPoll: Bool {
        isStarted && isActive && permission != .denied && availability == .running
    }

    private func updateScheduling() {
        if canPoll { startPolling() } else { stopPolling() }
        if isStarted && permission == .denied { startPermissionWatch() } else { stopPermissionWatch() }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.poll()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// A hand-edited 0 (or negative) would turn the poll loop into a tight
    /// Apple Event storm against Spotify; never poll faster than 4 Hz.
    nonisolated static func effectiveInterval(_ configured: Double) -> TimeInterval {
        configured.isFinite ? max(configured, 0.25) : 1
    }

    private var pollInterval: TimeInterval {
        let current = config.current
        let configured = snapshot.state == .playing ? current.pollIntervalPlaying : current.pollIntervalPaused
        return Self.effectiveInterval(configured)
    }

    /// One poll in flight at a time. A tick arriving mid-poll is dropped, never
    /// queued — a backlog of Apple Events against a wedged Spotify helps nobody.
    private func poll() {
        guard canPoll, !isPolling else { return }
        isPolling = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isPolling = false }
            do {
                self.apply(try await self.source.snapshot())
            } catch {
                self.handle(error)
            }
        }
    }

    private func apply(_ new: NowPlayingSnapshot) {
        consecutiveFailures = 0
        // Assignments are guarded on inequality throughout: @Observable notifies on
        // every set, and a 1 Hz stream of no-op sets would redraw the bar for nothing.
        if lastError != nil { lastError = nil }

        var cadenceChanged = (snapshot.state == .playing) != (new.state == .playing)
        if availability != .running {
            availability = .running
            cadenceChanged = true
        }
        // A reply is proof the grant exists, whatever the silent check said.
        if permission != .granted {
            permission = .granted
            cadenceChanged = true
        }

        // The playhead moves on every poll, but the clock already predicts it.
        // Only a reading it didn't expect (a new track or state, a seek, a
        // stall) republishes the snapshot and re-anchors the clock, so a song
        // playing steadily wakes no observer between its changes.
        let uptime = ProcessInfo.processInfo.systemUptime
        let isPlaying = new.state == .playing
        let duration = new.track?.duration ?? 0
        let expected = snapshot.state == new.state && snapshot.track == new.track
            && clock.agrees(position: new.position, uptime: uptime, isPlaying: isPlaying, duration: duration)
        if !expected {
            if snapshot != new { snapshot = new }
            let jumped = clock.reanchor(position: new.position, uptime: uptime,
                                        isPlaying: isPlaying, duration: duration)
            if jumped { lastSeekDetectedAt = uptime }
        }

        // Playing <-> paused changes the tick rate; restart the loop so the new
        // interval takes effect now rather than after the old one elapses.
        if cadenceChanged {
            stopPolling()
            updateScheduling()
        }
    }

    private func handle(_ error: Error) {
        let spotifyError = (error as? SpotifyError) ?? .malformedResponse
        if lastError != spotifyError { lastError = spotifyError }
        NSLog("[Lyrical] spotify error: %@", "\(spotifyError)")

        switch spotifyError {
        case .permissionDenied:
            permission = .denied
            consecutiveFailures = 0
            updateScheduling()
        case .permissionUndetermined:
            // Rare (NSAppleScript normally prompts rather than returning this).
            // Counted as a failure so we can't spin at 1 Hz asking for consent.
            permission = .undetermined
            consecutiveFailures += 1
            if consecutiveFailures >= 3 { markGone(.notRunning) }
        case .notInstalled:
            markGone(.notInstalled)
        case .notRunning:
            markGone(.notRunning)
        case .timedOut, .malformedResponse, .scriptError:
            consecutiveFailures += 1
            // Spotify wedged or gone weird: stop pestering it and let the launch
            // notification / next manual refresh bring us back.
            if consecutiveFailures >= 3 { markGone(.notRunning) }
        }
    }

    private func markGone(_ state: SpotifyAvailability) {
        consecutiveFailures = 0
        if availability != state { availability = state }
        // Keep `snapshot` — the UI decides whether to keep the art up — but freeze
        // the playhead so the bar doesn't keep crawling for a dead player.
        clock.isPlaying = false
        updateScheduling()
    }

    private func updateAvailability() {
        let current = source.availability()
        guard current != availability else { return }
        availability = current
        if current != .running { clock.isPlaying = false }
        updateScheduling()
    }

    // MARK: - Permission

    private func startPermissionWatch() {
        guard permissionTask == nil else { return }
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.permissionRecheckInterval))
                guard !Task.isCancelled, let self else { return }
                // Poll the status only. Re-asking in a loop is what produces a
                // dialog storm; the user grants this in System Settings.
                guard let state = await Self.checkPermission(self.permissionCheck, timeout: self.permissionTimeout),
                      state != .denied else { continue }
                self.permission = state
                self.updateScheduling()
                self.refreshNow()
                return
            }
        }
    }

    private func checkPermissionInBackground() {
        let check = permissionCheck
        let timeout = permissionTimeout
        Task { [weak self] in
            guard let state = await Self.checkPermission(check, timeout: timeout) else {
                NSLog("[Lyrical] automation permission check timed out — relying on the first poll")
                return
            }
            guard let self, self.isStarted else { return }
            // A poll reply may already have proven the grant; don't downgrade it.
            guard self.permission == .undetermined, state != .undetermined else { return }
            self.permission = state
            self.updateScheduling()
        }
    }

    /// Runs a possibly-blocking permission check on a background thread and gives
    /// up after `timeout`. A check that never returns leaks one parked thread,
    /// which beats a frozen app.
    nonisolated static func checkPermission(_ check: @escaping @Sendable () -> AutomationPermissionState,
                                            timeout: TimeInterval) async -> AutomationPermissionState? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let state = check()
                if once.claim() { continuation.resume(returning: state) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private func stopPermissionWatch() {
        permissionTask?.cancel()
        permissionTask = nil
    }

    // MARK: - Observers

    private func registerObservers() {
        let workspace = NSWorkspace.shared.notificationCenter

        observers.append(workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard Self.isSpotify(note) else { return }
            MainActor.assumeIsolated { self?.spotifyDidLaunch() }
        })

        observers.append(workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard Self.isSpotify(note) else { return }
            MainActor.assumeIsolated { self?.spotifyDidTerminate() }
        })

        // Edge trigger only: the payload's key names vary by Spotify build and
        // cross-process userInfo has been restricted since Catalina. We just poll.
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("\(SpotifyBridge.bundleID).PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    private func removeObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers { workspace.removeObserver(observer) }
        observers.removeAll()

        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
            self.distributedObserver = nil
        }
    }

    private nonisolated static func isSpotify(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == SpotifyBridge.bundleID
    }

    private func spotifyDidLaunch() {
        NSLog("[Lyrical] Spotify launched")
        availability = .running
        consecutiveFailures = 0
        updateScheduling()
        refreshNow()
    }

    private func spotifyDidTerminate() {
        NSLog("[Lyrical] Spotify quit")
        markGone(.notRunning)
    }
}
