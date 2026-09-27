//
//  SungLineView.swift
//  Lyrical
//
//  One lyric line whose words come alive as they're sung. Each line gets
//  one of a few styles (SungLineVariant), and in all of them a word keeps
//  growing for as long as it's held. It's done in a TextRenderer, so the
//  line is laid out once and never re-wraps mid-song; a swelling word
//  pushes its neighbours aside as it's drawn instead.
//  Only the lit line ticks, once per frame while Spotify plays. Every other
//  line, and the lit one when paused, draws once and sits still.
//

import SwiftUI

struct SungLineView: View {
    let line: LyricLine
    let variant: SungLineVariant
    let isLit: Bool
    let isPlaying: Bool
    let fontSize: CGFloat
    let centered: Bool
    /// Playback position for word timing, read on each frame.
    let position: () -> TimeInterval

    var body: some View {
        if let words = line.words, !words.isEmpty {
            let text = Self.text(for: words)
            TimelineView(.animation(paused: !(isLit && isPlaying))) { _ in
                text.textRenderer(SungWordsRenderer(words: words, variant: variant,
                                                    time: isLit ? position() : nil,
                                                    fontSize: fontSize, centered: centered))
            }
        } else {
            Text(line.text)
        }
    }

    /// The words as one Text, each tagged with its index so the renderer can
    /// find it. Spaces stay untagged: a word scales about its own letters.
    static func text(for words: [LyricWord]) -> Text {
        var result = Text(verbatim: "")
        for (index, word) in words.enumerated() {
            var body = word.text
            var gap = ""
            while let last = body.last, last.isWhitespace {
                gap.insert(body.removeLast(), at: gap.startIndex)
            }
            let tagged = Text(verbatim: body).customAttribute(WordAttribute(index: index))
            result = Text("\(result)\(tagged)\(Text(verbatim: gap))")
        }
        return result
    }
}

struct WordAttribute: TextAttribute {
    var index: Int
}

/// Draws the lit line word by word. Not animatable on purpose: the time
/// comes from the TimelineView each frame, and a line's spring into place
/// must not interpolate it.
struct SungWordsRenderer: TextRenderer {
    let words: [LyricWord]
    let variant: SungLineVariant
    /// nil for a line that isn't lit: it draws plainly.
    let time: TimeInterval?
    let fontSize: CGFloat
    let centered: Bool

    var displayPadding: EdgeInsets {
        let pad = fontSize * 1.2
        return EdgeInsets(top: pad, leading: pad, bottom: pad, trailing: pad)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard let time else {
            for line in layout { context.draw(line) }
            return
        }
        for line in layout {
            let runs = line.map { run -> (run: Text.Layout.Run, index: Int?, look: WordLook) in
                guard let index = run[WordAttribute.self]?.index, words.indices.contains(index) else {
                    return (run, nil, SungWordStyle.resting)
                }
                return (run, index, SungWordStyle.look(for: words[index], index: index, at: time, variant: variant))
            }
            let extras = runs.map { ($0.look.scale - 1) * $0.run.typographicBounds.width }
            let spread = SungWordStyle.spread(extras: extras, centered: centered)

            for (position, item) in runs.enumerated() {
                var word = context
                word.translateBy(x: spread[position], y: 0)
                guard item.index != nil else {
                    word.draw(item.run)
                    continue
                }
                draw(item.run, look: item.look, in: &word)
            }
        }
    }

    private func draw(_ run: Text.Layout.Run, look: WordLook, in word: inout GraphicsContext) {
        let bounds = run.typographicBounds.rect
        word.opacity = look.opacity
        word.translateBy(x: bounds.midX, y: bounds.midY - look.lift * fontSize)
        word.rotate(by: .degrees(look.rotation))
        word.scaleBy(x: look.scale, y: look.scale)
        word.translateBy(x: -bounds.midX, y: -bounds.midY)
        if look.blur > 0.001 {
            word.addFilter(.blur(radius: look.blur * fontSize))
        }
        if look.glow > 0.01 {
            word.addFilter(.shadow(color: .white.opacity(min(0.5 * look.glow, 0.8)),
                                   radius: fontSize * (0.2 + 0.1 * look.glow)))
        }
        guard let sweep = look.sweep else {
            word.draw(run)
            return
        }
        // Ripple: letters hop one after another as the sweep passes them.
        let count = max(run.count, 1)
        for (letter, slice) in run.enumerated() {
            let hop = look.hop * SungWordStyle.letterHop(sweep: sweep, letter: letter, of: count)
            var glyph = word
            glyph.translateBy(x: 0, y: -hop * fontSize)
            glyph.draw(slice)
        }
    }
}

/// The per-line animation styles. Chosen by the line's text, so a chorus
/// looks the same each time it comes round, but never the same as the line
/// just before it.
enum SungLineVariant: Int, CaseIterable {
    /// Swells, lifts and glows.
    case pop
    /// Waits low and small, then springs up into place.
    case rise
    /// Letters hop one after another across the word.
    case ripple
    /// Comes into focus out of a blur with a strong glow.
    case bloom
    /// Tips to one side, alternating word by word.
    case sway

    static func variants(for lines: [LyricLine]) -> [SungLineVariant] {
        var result: [SungLineVariant] = []
        var previous: SungLineVariant?
        for line in lines {
            let key = line.text.lowercased().filter { $0.isLetter || $0.isNumber }
            var variant = allCases[Int(StableHash.fnv1a(key) % UInt64(allCases.count))]
            if variant == previous { variant = allCases[(variant.rawValue + 1) % allCases.count] }
            result.append(variant)
            if !line.isGap { previous = variant }
        }
        return result
    }
}

/// How one word looks at a moment, as pure numbers so the feel can be tested.
struct WordLook: Equatable {
    var scale: CGFloat = 1
    /// Upward shift as a fraction of the font size.
    var lift: CGFloat = 0
    var opacity: Double = 1
    var glow: Double = 0
    var rotation: Double = 0
    /// Blur radius as a fraction of the font size.
    var blur: CGFloat = 0
    /// Ripple only: how far the hop has travelled through the letters (0…1
    /// across the word, then on past it) and how high it goes, in font sizes.
    var sweep: Double?
    var hop: CGFloat = 0
}

enum SungWordStyle {
    /// Words not reached yet sit dimmed, so the sung part reads as a sweep.
    static let unsungOpacity = 0.45
    /// Swell on the word's first beat.
    static let popScale: CGFloat = 0.08
    /// Extra size per second a word is held, up to a limit, so a long note
    /// visibly keeps growing.
    static let growthPerSecond: CGFloat = 0.28
    static let maxGrowth: CGFloat = 0.8
    static let popLift: CGFloat = 0.06
    static let attack: TimeInterval = 0.12
    static let release: TimeInterval = 0.5

    static let resting = WordLook()

    static func look(for word: LyricWord, index: Int, at time: TimeInterval,
                     variant: SungLineVariant) -> WordLook {
        let lit = ease((time - word.start) / attack)
        let fade = time <= word.end ? 1 : 1 - ease((time - word.end) / release)
        let emphasis = lit * fade
        let swell = CGFloat(emphasis) * (popScale + growth(for: word, at: time))
        let brighten = { (from: Double) in from + (1 - from) * lit }

        switch variant {
        case .pop:
            return WordLook(scale: 1 + swell, lift: popLift * CGFloat(emphasis),
                            opacity: brighten(unsungOpacity), glow: emphasis)
        case .rise:
            let arrive = CGFloat(backOut(clamp((time - word.start) / 0.35)))
            return WordLook(scale: 0.88 + 0.12 * arrive + swell,
                            lift: -0.18 * (1 - arrive) + 0.04 * CGFloat(emphasis),
                            opacity: brighten(0.3), glow: 0.6 * emphasis)
        case .ripple:
            // Unclamped, so after the word ends the hop runs on off its last
            // letter instead of snapping down.
            // The hop shrinks as the word settles, so no letter ever drops.
            let sweep = (time - word.start) / max(word.end - word.start, 0.3)
            let playing = lit > 0 && fade > 0
            return WordLook(scale: 1 + swell * 0.8, opacity: brighten(unsungOpacity),
                            glow: 0.7 * emphasis, sweep: playing ? sweep : nil,
                            hop: playing ? 0.12 * CGFloat(fade) : 0)
        case .bloom:
            return WordLook(scale: 1 + swell, opacity: brighten(0.35),
                            glow: 1.6 * emphasis, blur: 0.06 * CGFloat(1 - lit))
        case .sway:
            let side: Double = index.isMultiple(of: 2) ? 1 : -1
            return WordLook(scale: 1 + swell, lift: 0.03 * CGFloat(emphasis),
                            opacity: brighten(unsungOpacity), glow: emphasis,
                            rotation: side * 6 * emphasis)
        }
    }

    /// Size gained from holding the word: proportional to seconds held.
    static func growth(for word: LyricWord, at time: TimeInterval) -> CGFloat {
        let held = max(min(time, word.end) - word.start, 0)
        return min(CGFloat(held) * growthPerSecond, maxGrowth)
    }

    /// How far each run slides sideways so swollen words don't overlap:
    /// everything after a word moves along by its extra width, and a
    /// centred line then re-centres.
    static func spread(extras: [CGFloat], centered: Bool) -> [CGFloat] {
        let total = extras.reduce(0, +)
        var before: CGFloat = 0
        return extras.map { extra in
            defer { before += extra }
            return before + extra / 2 - (centered ? total / 2 : 0)
        }
    }

    /// Height of letter `letter`'s hop, 0…1 of the full hop.
    static func letterHop(sweep: Double, letter: Int, of count: Int) -> CGFloat {
        let center = (Double(letter) + 0.5) / Double(count)
        let distance = abs(sweep - center) * Double(count) / 2.5
        guard distance < 1 else { return 0 }
        return CGFloat(cos(distance * .pi / 2))
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    /// Smoothstep: eases in and out, flat at both ends.
    private static func ease(_ value: Double) -> Double {
        let x = clamp(value)
        return x * x * (3 - 2 * x)
    }

    /// Overshoots a little and settles, like a spring.
    private static func backOut(_ x: Double) -> Double {
        let c = 1.70158
        let t = x - 1
        return 1 + (c + 1) * t * t * t + c * t * t
    }
}
