//
//  CarouselStyle.swift
//  Lyrical
//
//  Every number the carousel draws with, as pure functions so the look can be
//  tested and tuned without launching anything. CarouselMetrics turns the
//  (hand-edited, untrusted) config into sane pixel values for one screen.
//

import SwiftUI

struct CarouselMetrics: Equatable {
    var fontSize: CGFloat
    var columnWidth: CGFloat
    var anchorY: CGFloat
    var lineSpacing: CGFloat
    var alignment: TextAlignmentOption
    var design: FontDesignOption
    var blurInactive: Bool

    init(config: LyricalConfig, screenSize: CGSize) {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> CGFloat {
            CGFloat(value.isFinite ? min(max(value, low), high) : low)
        }
        fontSize = clamp(config.fontSizeFraction, 0.015, 0.12) * screenSize.height
        columnWidth = clamp(config.columnWidthFraction, 0.2, 0.95) * screenSize.width
        anchorY = clamp(config.anchorYFraction, 0.1, 0.9) * screenSize.height
        lineSpacing = fontSize * 0.55
        alignment = config.textAlignment
        design = config.fontDesign
        blurInactive = config.blurInactive
    }

    var horizontalAlignment: HorizontalAlignment { alignment == .leading ? .leading : .center }
    var frameAlignment: Alignment { alignment == .leading ? .leading : .center }
    var textAlignment: TextAlignment { alignment == .leading ? .leading : .center }
    var scaleAnchor: UnitPoint { alignment == .leading ? .leading : .center }

    var fontDesign: Font.Design {
        switch design {
        case .standard: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        }
    }
}

enum CarouselStyle {
    /// Lines further than this from the focus are laid out but not drawn.
    static let renderRadius = 10
    static let staggerPerLine = 0.035
    static let inactiveScale: CGFloat = 0.86

    private static let opacities: [Double] = [1.0, 0.55, 0.38, 0.25, 0.15]
    private static let blurs: [CGFloat] = [0, 0, 1.2, 2.4, 3.6]

    static func opacity(distance: Int) -> Double {
        guard distance <= renderRadius else { return 0 }
        return opacities[min(distance, opacities.count - 1)]
    }

    static func blur(distance: Int, enabled: Bool) -> CGFloat {
        guard enabled, distance <= renderRadius else { return 0 }
        return blurs[min(distance, blurs.count - 1)]
    }

    static func scale(distance: Int) -> CGFloat {
        distance == 0 ? 1 : inactiveScale
    }

    /// Before the first line nothing is lit, so every line counts one further away.
    static func distance(of index: Int, active: Int?) -> Int {
        guard let active else { return index + 1 }
        return abs(index - active)
    }

    /// Y offset that puts the middle of line `focus` on `anchorY`.
    static func offset(focus: Int, heights: [Int: CGFloat], estimate: CGFloat,
                       spacing: CGFloat, anchorY: CGFloat) -> CGFloat {
        var top: CGFloat = 0
        for index in 0..<max(focus, 0) {
            top += (heights[index] ?? estimate) + spacing
        }
        return anchorY - (top + (heights[focus] ?? estimate) / 2)
    }

    static func animation(for move: LyricsMove, distance: Int) -> Animation {
        switch move {
        case .advance:
            return .spring(response: 0.55, dampingFraction: 0.85).delay(Double(distance) * staggerPerLine)
        case .jump:
            return .easeOut(duration: 0.25)
        }
    }
}
