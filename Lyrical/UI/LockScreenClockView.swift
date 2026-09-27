//
//  LockScreenClockView.swift
//  Lyrical
//
//  On the lock screen the backdrop covers the system's date and time, so we
//  draw our own in the same spot: date over a large time, top-centre. Like
//  the macOS 26 lock screen, the time is Liquid Glass cut in the shape of the
//  digits, refracting the backdrop behind it, set in the same clock face and
//  weight the user picked in System Settings › Wallpaper › Clock Appearance.
//

import AppKit
import SwiftUI

struct LockScreenClockView: View {
    let screenSize: CGSize
    let design: Font.Design

    var body: some View {
        TimelineView(.everyMinute) { context in
            let timeSize = screenSize.height * 0.12
            // Re-read each minute so a change in System Settings shows up.
            let timeFont = SystemClockFont.current(size: timeSize) ?? GlyphShape.fallbackFont(size: timeSize, design: design)
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
                                 in: GlyphShape(text: Self.time(context.date), font: timeFont))
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

/// The outlines of `text` in `font`, centred in the rect, so a material can be
/// clipped to the letterforms.
struct GlyphShape: Shape {
    let text: String
    // Shape is Sendable; CTFont is immutable and safe to share across threads.
    nonisolated(unsafe) let font: CTFont

    func path(in rect: CGRect) -> Path {
        let glyphs = Self.outline(text, font: font)
        let bounds = glyphs.boundingBoxOfPath
        guard !bounds.isNull else { return Path() }
        // CoreText draws y-up; flip, then centre the ink in the rect.
        var transform = CGAffineTransform(translationX: rect.midX - bounds.midX, y: rect.midY + bounds.midY)
            .scaledBy(x: 1, y: -1)
        return Path(glyphs.copy(using: &transform) ?? glyphs)
    }

    /// Semibold system font in the lyrics' design, for when the system clock
    /// faces can't be loaded. Tabular digits so the time doesn't shuffle
    /// sideways as it changes.
    static func fallbackFont(size: CGFloat, design: Font.Design) -> CTFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let descriptor = base.fontDescriptor.withDesign(systemDesign(design)) ?? base.fontDescriptor
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

/// The lock screen clock face. The system draws its clock from private numeric
/// fonts in ADTNumeric.ttc, picking the face and weight from loginwindow's
/// ClockFontIdentifier and ClockFontWeight (what System Settings › Wallpaper ›
/// Clock Appearance writes). Using the same font file and settings makes our
/// clock the same letterforms as the one the backdrop covers.
enum SystemClockFont {
    static let defaultIdentifier = "adaptiveSoft"

    /// The identifiers loginwindow accepts, mapped to their font family's
    /// PostScript prefix, as loginwindow pairs them.
    static let families: [String: String] = [
        "adaptiveSoft": ".SFAdaptiveSoftNumeric",
        "soft": ".SFSoftNumeric",
        "rounded": ".SFRoundedNumeric",
        "stencil": ".SFStencilNumeric",
        "newYork": ".NewYorkSoftNumeric",
        "slab": ".ADTSlabSoftNumeric",
        "rail": ".SFRailRoundedNumeric",
    ]

    private static let fontFile = URL(fileURLWithPath: "/System/Library/Fonts/ADTNumeric.ttc")

    /// Every face in the collection, loaded once; there are about a thousand.
    private static let descriptors: [CTFontDescriptor] =
        CTFontManagerCreateFontDescriptorsFromURL(fontFile as CFURL) as? [CTFontDescriptor] ?? []

    /// The user's chosen clock font, or nil if the fonts aren't on this Mac.
    static func current(size: CGFloat) -> CTFont? {
        let domain = "com.apple.loginwindow" as CFString
        CFPreferencesAppSynchronize(domain)
        let identifier = CFPreferencesCopyAppValue("ClockFontIdentifier" as CFString, domain) as? String
        let weight = (CFPreferencesCopyAppValue("ClockFontWeight" as CFString, domain) as? NSNumber)?.doubleValue
        return font(identifier: identifier, weight: weight, size: size)
    }

    static func font(identifier: String?, weight: Double?, size: CGFloat) -> CTFont? {
        let family = families[identifier ?? ""] ?? families[defaultIdentifier]!
        guard let regular = descriptor(family + "-Regular") else { return nil }
        guard let weight, let coordinate = axisCoordinate(forWeight: weight, family: family) else {
            return CTFontCreateWithFontDescriptor(regular, size, nil)
        }
        let varied = CTFontDescriptorCreateCopyWithVariation(regular, wght as CFNumber, CGFloat(coordinate))
        return CTFontCreateWithFontDescriptor(varied, size, nil)
    }

    /// The system weight scale's named weights, as the SF faces set them.
    private static let namedWeights: [(name: String, weight: Double)] = [
        ("Ultrathin", 1), ("Ultralight", 30.925), ("Thin", 110.725), ("Light", 274.315), ("Regular", 400),
        ("Medium", 510), ("Semibold", 590), ("Bold", 700), ("Heavy", 860), ("Black", 1000),
    ]

    private static let wght = 0x7767_6874

    /// The setting is on the system weight scale, but each face's weight axis
    /// has its own (Rail's Regular sits at 200.5, its Black at 400). Map it
    /// through the face's named instances so 400 is that face's Regular, 700
    /// its Bold, and so on, interpolating in between.
    static func axisCoordinate(forWeight weight: Double, family: String) -> Double? {
        let anchors: [(weight: Double, coordinate: Double)] = namedWeights.compactMap { named in
            guard let descriptor = descriptor(family + "-" + named.name) else { return nil }
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
            // A named instance at the axis default leaves it out of its variation.
            guard let coordinate = variation?[NSNumber(value: wght)]?.doubleValue ?? weightAxisDefault(of: font)
            else { return nil }
            return (named.weight, coordinate)
        }
        guard let first = anchors.first, let last = anchors.last else { return nil }
        if weight <= first.weight { return first.coordinate }
        if weight >= last.weight { return last.coordinate }
        let upper = anchors.firstIndex { $0.weight >= weight }!
        let (a, b) = (anchors[upper - 1], anchors[upper])
        return a.coordinate + (weight - a.weight) / (b.weight - a.weight) * (b.coordinate - a.coordinate)
    }

    private static func descriptor(_ postScriptName: String) -> CTFontDescriptor? {
        descriptors.first { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String == postScriptName }
    }

    private static func weightAxisDefault(of font: CTFont) -> Double? {
        let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] ?? []
        let axis = axes.first { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.intValue == wght }
        return (axis?[kCTFontVariationAxisDefaultValueKey] as? NSNumber)?.doubleValue
    }
}
