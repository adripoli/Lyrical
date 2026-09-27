//
//  ControlBarView.swift
//  Lyrical
//
//  Contents of the ControlPanelWindow: track text, progress, transport. Sits at
//  rest opacity and brightens on hover so it stays unobtrusive on a desktop you
//  are mostly not looking at.
//

import SwiftUI

struct ControlBarView: View {
    let nowPlaying: NowPlayingStore
    var config: LyricalConfig
    /// False while nobody can see the bar (screen locked, displays asleep):
    /// the progress then holds still instead of ticking.
    var isLive = true

    @Environment(\.displayScale) private var displayScale
    @State private var isHovering = false
    /// Non-nil only while a drag is in flight; it overrides the interpolated
    /// position so the bar follows the pointer instead of fighting the clock.
    @State private var scrubFraction: Double?
    /// The seek bar's drawn width, for pacing redraws. Starts as an estimate
    /// of the default layout until the first layout measures it.
    @State private var barWidth: CGFloat = 400

    private var track: TrackInfo? { nowPlaying.snapshot.track }
    private var duration: TimeInterval { track?.duration ?? 0 }
    private var isPlaying: Bool { nowPlaying.snapshot.state == .playing }
    private var isAd: Bool { track?.isAd == true }

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassPanel()
            .opacity(isHovering ? config.controlBarHoverOpacity : config.controlBarOpacity)
            .animation(.easeInOut(duration: 0.18), value: isHovering)
            .onHover { isHovering = $0 }
    }

    // MARK: - States

    /// Strict precedence: the recovery states outrank anything we could say about
    /// a track, because a stale title over a dead player is what "looks broken"
    /// actually means.
    @ViewBuilder
    private var content: some View {
        if nowPlaying.permission == .denied {
            message("Lyrical needs permission to control Spotify",
                    action: "Open Settings…",
                    perform: AutomationPermission.openSystemSettings)
        } else if nowPlaying.availability == .notInstalled {
            message("Spotify isn't installed")
        } else if nowPlaying.availability == .notRunning {
            message("Spotify isn't running", action: "Open Spotify") { nowPlaying.openSpotify() }
        } else {
            player
        }
    }

    private func message(_ text: String, action: String? = nil,
                         perform: (() -> Void)? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)

            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let action, let perform {
                Button(action, action: perform)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }

    private var player: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track?.name ?? "Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(track?.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.tail)

                Spacer(minLength: 8)

                HStack(spacing: 16) {
                    TransportButton(symbol: "backward.fill", size: 14) { nowPlaying.previous() }
                        .disabled(isAd)
                    TransportButton(symbol: isPlaying ? "pause.fill" : "play.fill", size: 18) {
                        nowPlaying.playPause()
                    }
                    TransportButton(symbol: "forward.fill", size: 14) { nowPlaying.next() }
                        .disabled(isAd)
                }
            }

            if track != nil { progress }
        }
    }

    // MARK: - Progress

    /// Only the bar redraws — the rest of the panel's layout stays out of the
    /// schedule — and only as often as ProgressCadence says it visibly moves.
    /// Nothing ticks while the playhead is frozen or nobody can see the bar;
    /// a periodic schedule against a stopped clock is pure waste.
    @ViewBuilder
    private var progress: some View {
        if isPlaying && isLive {
            TimelineView(progressSchedule) { _ in progressRow }
        } else {
            progressRow
        }
    }

    /// Rebuilt whenever a poll re-anchors the clock, which keeps the ticks
    /// aligned to Spotify's playhead.
    private var progressSchedule: PeriodicTimelineSchedule {
        let interval = ProgressCadence.interval(duration: duration, barWidth: barWidth, scale: displayScale,
                                                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        let start = ProgressCadence.scheduleStart(position: nowPlaying.displayPosition, interval: interval, now: .now)
        return .periodic(from: start, by: interval)
    }

    private var progressRow: some View {
        let live = duration > 0 ? nowPlaying.displayPosition / duration : 0
        let shown = min(max(scrubFraction ?? live, 0), 1)

        return HStack(spacing: 8) {
            timeLabel(shown * duration)
            SeekBar(fraction: shown, isEnabled: duration > 0 && !isAd) { fraction in
                scrubFraction = fraction
            } onCommit: { fraction in
                // seek() re-anchors the clock optimistically, so clearing the scrub
                // override right here can't snap back to the old position.
                nowPlaying.seek(to: fraction * duration)
                scrubFraction = nil
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
            timeLabel(duration)
        }
    }

    private func timeLabel(_ seconds: TimeInterval) -> some View {
        Text(Self.timecode(seconds))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 34, alignment: .center)
    }

    /// Hand-rolled because this runs several times a second: a DateComponentsFormatter
    /// here would allocate and locale-negotiate for a string we already know the
    /// shape of.
    static func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        guard hours == 0 else {
            return String(format: "%d:%02d:%02d", hours, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Cadence

/// How often the progress row redraws while a song plays. The bar sits under
/// Liquid Glass, so every redraw also has WindowServer re-render the glass:
/// on an Intel Mac a fixed 10 Hz cost more in WindowServer than in Lyrical.
/// So it redraws only as often as something visibly moves: the fill by a
/// device pixel, or the elapsed time by a second.
enum ProgressCadence {
    static let maxPerSecond = 10.0
    /// How long after each step of the playhead a tick lands, so the elapsed
    /// time has already rolled over to the new second when it's drawn.
    static let lag: TimeInterval = 0.01

    /// Seconds between redraws: often enough that the fill moves at most a
    /// device pixel per redraw, at least once a second for the label, at most
    /// ten times a second. Always 1/n of a second, so ticks aligned to the
    /// playhead land on every whole second. Low Power Mode draws once a second.
    static func interval(duration: TimeInterval, barWidth: CGFloat, scale: CGFloat,
                         lowPower: Bool = false) -> TimeInterval {
        guard !lowPower, duration.isFinite, duration > 0 else { return 1 }
        let pixelsPerSecond = Double(max(barWidth, 0) * max(scale, 1)) / duration
        return 1 / min(max(pixelsPerSecond.rounded(.up), 1), maxPerSecond)
    }

    /// A start for a periodic schedule whose ticks fall `lag` after each
    /// multiple of `interval` on the playhead. Never in the future: a
    /// schedule that starts later draws its first frame late.
    static func scheduleStart(position: TimeInterval, interval: TimeInterval, now: Date) -> Date {
        let phase = (position - lag).truncatingRemainder(dividingBy: interval)
        return now.addingTimeInterval(-(phase < 0 ? phase + interval : phase))
    }
}

// MARK: - Seek bar

/// Thin to look at, thick to hit: 6pt of capsule inside a 20pt hit area, because
/// a 6pt click target on a desktop overlay is a dexterity test, not a scrubber.
private struct SeekBar: View {
    var fraction: Double
    var isEnabled: Bool
    var onScrub: (Double) -> Void
    var onCommit: (Double) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private static let trackHeight: CGFloat = 6
    private static let hitHeight: CGFloat = 20
    private static let knob: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let filled = width * min(max(fraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.18)).frame(height: Self.trackHeight)
                Capsule().fill(.primary.opacity(0.85)).frame(width: filled, height: Self.trackHeight)

                if isEnabled && (isHovering || isDragging) {
                    Circle()
                        .fill(.primary)
                        .frame(width: Self.knob, height: Self.knob)
                        .offset(x: min(max(filled - Self.knob / 2, 0), width - Self.knob))
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                }
            }
            .frame(width: width, height: geo.size.height)
            // Never inherit an ancestor's implicit animation here: an external seek
            // must jump, not slide the width of the screen.
            .animation(nil, value: fraction)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        onScrub(Self.fraction(at: value.location.x, width: width))
                    }
                    .onEnded { value in
                        isDragging = false
                        onCommit(Self.fraction(at: value.location.x, width: width))
                    }
            )
            .onHover { isHovering = $0 }
        }
        .frame(height: Self.hitHeight)
        .disabled(!isEnabled)
    }

    private static func fraction(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
    }
}

// MARK: - Transport

private struct TransportButton: View {
    var symbol: String
    var size: CGFloat
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.primary.opacity(isHovering ? 0.15 : 0)))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 && isEnabled }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
