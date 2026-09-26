//
//  TitleCardView.swift
//  Lyrical
//
//  Shown whenever there are no synced lyrics to scroll: loading, no lyrics,
//  instrumental, offline, ads. Deliberate-looking, not an error screen.
//

import SwiftUI

struct TitleCardView: View {
    let track: TrackInfo?
    let status: String?
    let metrics: CarouselMetrics

    var body: some View {
        VStack(spacing: metrics.fontSize * 0.3) {
            if let track {
                Text(track.name)
                    .font(.system(size: metrics.fontSize * 1.4, weight: .bold, design: metrics.fontDesign))
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: metrics.fontSize * 0.75, weight: .semibold, design: metrics.fontDesign))
                        .opacity(0.7)
                }
            }
            if let status {
                Text(status)
                    .font(.system(size: metrics.fontSize * 0.45, weight: .medium, design: metrics.fontDesign))
                    .opacity(0.5)
                    .padding(.top, metrics.fontSize * 0.4)
                    .contentTransition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .frame(width: metrics.columnWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: status)
        .allowsHitTesting(false)
    }
}
