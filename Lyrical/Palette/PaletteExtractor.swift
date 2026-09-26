//
//  PaletteExtractor.swift
//  Lyrical
//
//  Album cover → four dark, related colours for the mesh-gradient backdrop.
//  The cover is shrunk to 24×24 and chromatic pixels are bucketed by hue.
//  The biggest buckets are averaged in RGB (hue can't be averaged
//  directly: 0.99 and 0.01 are neighbours). Every colour is clamped
//  under a brightness cap so white text always reads. Pure CoreGraphics,
//  safe off the main thread.
//

import CoreGraphics
import SwiftUI

struct PaletteColor: Equatable, Sendable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    func capped(_ cap: Double) -> PaletteColor {
        PaletteColor(hue: hue, saturation: saturation, brightness: min(brightness, cap))
    }

    func dimmed(_ factor: Double) -> PaletteColor {
        PaletteColor(hue: hue, saturation: saturation, brightness: brightness * factor)
    }

    var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }
}

struct Palette: Equatable, Sendable {
    /// Artwork content hash (or "fallback:<seed>"). The view crossfades on change.
    var key: String
    var colors: [PaletteColor]

    /// For tracks without artwork. The same seed always gives the same colours.
    static func fallback(seed: String, cap: Double) -> Palette {
        let hash = StableHash.fnv1a(seed)
        let hue = Double(hash % 360) / 360
        let spread = Double(25 + (hash >> 16) % 46) / 360
        let second = (hue + spread).truncatingRemainder(dividingBy: 1)
        let middle = (hue + spread / 2).truncatingRemainder(dividingBy: 1)
        let colors = [
            PaletteColor(hue: hue, saturation: 0.52, brightness: 0.34),
            PaletteColor(hue: second, saturation: 0.60, brightness: 0.26),
            PaletteColor(hue: middle, saturation: 0.55, brightness: 0.20),
            PaletteColor(hue: hue, saturation: 0.60, brightness: 0.14),
        ]
        return Palette(key: "fallback:\(seed)", colors: colors.map { $0.capped(PaletteExtractor.clampCap(cap)) })
    }
}

enum PaletteExtractor {

    static let sampleSide = 24
    static let hueBuckets = 12
    /// A hue must cover at least this share of the cover to make the palette.
    static let minShare = 0.03

    private struct Bucket {
        var count = 0
        var r = 0.0, g = 0.0, b = 0.0

        mutating func add(_ p: (Double, Double, Double)) {
            count += 1; r += p.0; g += p.1; b += p.2
        }

        var average: PaletteColor {
            let n = Double(max(count, 1))
            return PaletteExtractor.hsb(r: r / n, g: g / n, b: b / n)
        }
    }

    static func clampCap(_ cap: Double) -> Double {
        cap.isFinite ? min(max(cap, 0.05), 1) : 0.35
    }

    static func palette(from image: CGImage, key: String, brightnessCap: Double) -> Palette {
        let cap = clampCap(brightnessCap)
        let pixels = sample(image)
        guard !pixels.isEmpty else { return .fallback(seed: key, cap: cap) }

        var chromatic: [Int: Bucket] = [:]
        var neutral = Bucket()
        for p in pixels {
            let c = hsb(r: p.0, g: p.1, b: p.2)
            if c.saturation < 0.18 || c.brightness < 0.08 {
                neutral.add(p)
            } else {
                chromatic[Int(c.hue * Double(hueBuckets)) % hueBuckets, default: Bucket()].add(p)
            }
        }

        let threshold = max(Int(Double(pixels.count) * minShare), 1)
        var picks = chromatic.values
            .filter { $0.count >= threshold }
            .sorted { $0.count > $1.count }
            .prefix(4)
            .map(\.average)
        if picks.isEmpty { picks = [neutral.average] }   // grayscale art

        // Pad to four with progressively darker copies so the mesh has depth.
        let base = picks
        var round = 1
        while picks.count < 4 {
            picks.append(base[(picks.count - base.count) % base.count].dimmed(pow(0.72, Double(round))))
            if (picks.count - base.count) % base.count == 0 { round += 1 }
        }

        let finished = picks.map { color in
            PaletteColor(hue: color.hue,
                         saturation: min(1, color.saturation * 1.15),
                         brightness: min(color.brightness, cap))
        }
        return Palette(key: key, colors: finished)
    }

    static func hsb(r: Double, g: Double, b: Double) -> PaletteColor {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV

        var hue = 0.0
        if delta > 0 {
            if maxV == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return PaletteColor(hue: hue, saturation: maxV == 0 ? 0 : delta / maxV, brightness: maxV)
    }

    /// Opaque pixels of `image` scaled to sampleSide², as 0…1 RGB.
    private static func sample(_ image: CGImage) -> [(Double, Double, Double)] {
        let side = sampleSide
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }

        var pixels: [(Double, Double, Double)] = []
        pixels.reserveCapacity(side * side)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[i + 3]) / 255
            guard alpha > 0.5 else { continue }
            pixels.append((Double(bytes[i]) / 255 / alpha,
                           Double(bytes[i + 1]) / 255 / alpha,
                           Double(bytes[i + 2]) / 255 / alpha))
        }
        return pixels
    }
}
