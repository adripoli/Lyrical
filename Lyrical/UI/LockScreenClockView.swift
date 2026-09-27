//
//  LockScreenClockView.swift
//  Lyrical
//
//  On the lock screen the backdrop covers the system's date and time, so we
//  draw our own in the same spot: date over a large time, top-centre. Like
//  the macOS 26 lock screen, the time is Liquid Glass cut in the shape of the
//  digits, refracting the backdrop behind it.
//

import AppKit
import SwiftUI

struct LockScreenClockView: View {
    let screenSize: CGSize
    let design: Font.Design

    var body: some View {
        TimelineView(.everyMinute) { context in
            let timeSize = screenSize.height * 0.12
            VStack(spacing: screenSize.height * 0.02) {
                Text(context.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: screenSize.height * 0.028, weight: .semibold, design: design))
                    .foregroundStyle(.white)
                    .opacity(0.8)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                // glassEffect takes any Shape, so shaping the glass as the
                // glyph outlines gives glass digits rather than a glass pill.
                Color.clear
                    .frame(width: screenSize.width, height: timeSize * 0.8)
                    .glassEffect(.clear.tint(.white.opacity(0.8)),
                                 in: GlyphShape(text: Self.time(context.date), size: timeSize, design: design))
                    .accessibilityElement()
                    .accessibilityLabel(Text(context.date, format: .dateTime.hour().minute()))
            }
            .padding(.top, screenSize.height * 0.075)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }

    /// "6:21", or "18:21" on a 24-hour Mac, the way the system lock screen
    /// shows it. FormatStyle zero-pads a 12-hour hour once AM/PM is omitted.
    static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h"
        let is24Hour = pattern.contains("H") || pattern.contains("k")
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour24 = parts.hour ?? 0
        let hour = is24Hour ? hour24 : (hour24 % 12 == 0 ? 12 : hour24 % 12)
        return String(format: "%d:%02d", hour, parts.minute ?? 0)
    }
}

/// The outlines of `text` set in the semibold system font, centred in the
/// rect, so a material can be clipped to the letterforms.
struct GlyphShape: Shape {
    let text: String
    let size: CGFloat
    let design: Font.Design

    func path(in rect: CGRect) -> Path {
        let glyphs = Self.outline(text, font: font)
        let bounds = glyphs.boundingBoxOfPath
        guard !bounds.isNull else { return Path() }
        // CoreText draws y-up; flip, then centre the ink in the rect.
        var transform = CGAffineTransform(translationX: rect.midX - bounds.midX, y: rect.midY + bounds.midY)
            .scaledBy(x: 1, y: -1)
        return Path(glyphs.copy(using: &transform) ?? glyphs)
    }

    private var font: CTFont {
        // Tabular digits so the time doesn't shuffle sideways as it changes.
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let descriptor = base.fontDescriptor.withDesign(Self.systemDesign(design)) ?? base.fontDescriptor
        return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
    }

    private static func systemDesign(_ design: Font.Design) -> NSFontDescriptor.SystemDesign {
        switch design {
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        default: .default
        }
    }

    static func outline(_ text: String, font: CTFont) -> CGPath {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                var transform = CGAffineTransform(translationX: position.x, y: position.y)
                if let outline = CTFontCreatePathForGlyph(runFont, glyph, &transform) {
                    path.addPath(outline)
                }
            }
        }
        return path
    }
}
