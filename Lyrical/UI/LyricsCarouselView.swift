//
//  LyricsCarouselView.swift
//  Lyrical
//
//  The Apple Music-style list. Every line is laid out once in a VStack.
//  Each line then carries its own offset, and that offset animates with a
//  delay proportional to its distance from the lit line. That per-line delay
//  is what makes the list ripple upward as a wave instead of sliding as a slab.
//

import SwiftUI

struct LyricsCarouselView: View {
    let lines: [LyricLine]
    let activeIndex: Int?
    let move: LyricsMove
    let isPlaying: Bool
    let metrics: CarouselMetrics

    @State private var heights: [Int: CGFloat] = [:]

    var body: some View {
        let focus = min(activeIndex ?? 0, max(lines.count - 1, 0))
        let offset = CarouselStyle.offset(focus: focus, heights: heights,
                                          estimate: metrics.fontSize * 1.3,
                                          spacing: metrics.lineSpacing, anchorY: metrics.anchorY)

        VStack(alignment: metrics.horizontalAlignment, spacing: metrics.lineSpacing) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let distance = CarouselStyle.distance(of: index, active: activeIndex)

                row(line, isActive: index == activeIndex)
                    .frame(width: metrics.columnWidth, alignment: metrics.frameAlignment)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[index] = $0 }
                    .scaleEffect(CarouselStyle.scale(distance: distance), anchor: metrics.scaleAnchor)
                    .blur(radius: CarouselStyle.blur(distance: distance, enabled: metrics.blurInactive))
                    .opacity(CarouselStyle.opacity(distance: distance))
                    .offset(y: offset)
                    .animation(CarouselStyle.animation(for: move, distance: distance), value: activeIndex)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func row(_ line: LyricLine, isActive: Bool) -> some View {
        if line.isGap {
            GapDots(size: metrics.fontSize * 0.28, isAnimating: isActive && isPlaying)
                .frame(height: metrics.fontSize * 1.1)
        } else {
            // One weight for every line: a weight change on the lit line would
            // re-wrap it and make the list jitter mid-spring.
            Text(line.text)
                .font(.system(size: metrics.fontSize, weight: .bold, design: metrics.fontDesign))
                .foregroundStyle(.white)
                .multilineTextAlignment(metrics.textAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        }
    }
}

/// Three dots for an instrumental break. They breathe only while their gap
/// is the lit line and Spotify is playing; otherwise they hold still, so a
/// paused wallpaper costs nothing.
struct GapDots: View {
    let size: CGFloat
    let isAnimating: Bool

    var body: some View {
        if isAnimating {
            PhaseAnimator([false, true]) { dimmed in
                dots(dimmed: dimmed)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        } else {
            dots(dimmed: false)
        }
    }

    private func dots(dimmed: Bool) -> some View {
        HStack(spacing: size * 0.8) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(.white)
                    .frame(width: size, height: size)
            }
        }
        .opacity(dimmed ? 0.4 : 1)
        .scaleEffect(dimmed ? 0.85 : 1)
    }
}
