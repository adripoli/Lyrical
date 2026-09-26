//
//  PaletteExtractorTests.swift
//  LyricalTests
//

import XCTest
import CoreGraphics
@testable import Lyrical

final class PaletteExtractorTests: XCTestCase {

    /// `left` fills the left half, `right` the right half (same colour = solid).
    private func image(left: (Double, Double, Double), right: (Double, Double, Double)) -> CGImage {
        let side = 64
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: left.0, green: left.1, blue: left.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))
        ctx.setFillColor(CGColor(srgbRed: right.0, green: right.1, blue: right.2, alpha: 1))
        ctx.fill(CGRect(x: side / 2, y: 0, width: side / 2, height: side))
        return ctx.makeImage()!
    }

    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    func testHSBConversionKnownValues() {
        let red = PaletteExtractor.hsb(r: 1, g: 0, b: 0)
        XCTAssertEqual(red.hue, 0, accuracy: 0.001)
        XCTAssertEqual(red.saturation, 1, accuracy: 0.001)
        XCTAssertEqual(red.brightness, 1, accuracy: 0.001)
        XCTAssertEqual(PaletteExtractor.hsb(r: 0, g: 1, b: 0).hue, 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(PaletteExtractor.hsb(r: 0, g: 0, b: 1).hue, 2.0 / 3, accuracy: 0.001)
        XCTAssertEqual(PaletteExtractor.hsb(r: 0.5, g: 0.5, b: 0.5).saturation, 0, accuracy: 0.001)
    }

    func testSolidColourGivesThatHueCapped() {
        let palette = PaletteExtractor.palette(from: image(left: (1, 0, 0), right: (1, 0, 0)),
                                               key: "k", brightnessCap: 0.35)
        XCTAssertEqual(palette.colors.count, 4)
        XCTAssertEqual(palette.key, "k")
        for color in palette.colors {
            XCTAssertLessThan(hueDistance(color.hue, 0), 0.03)
            XCTAssertLessThanOrEqual(color.brightness, 0.35 + 1e-9)
        }
    }

    func testTwoColourImageKeepsBothHues() {
        let palette = PaletteExtractor.palette(from: image(left: (0, 0, 1), right: (1, 1, 0)),
                                               key: "k", brightnessCap: 0.35)
        let hues = palette.colors.map(\.hue)
        XCTAssertTrue(hues.contains { hueDistance($0, 2.0 / 3) < 0.03 }, "\(hues)")
        XCTAssertTrue(hues.contains { hueDistance($0, 1.0 / 6) < 0.03 }, "\(hues)")
    }

    func testGrayscaleStaysNeutral() {
        let palette = PaletteExtractor.palette(from: image(left: (0.2, 0.2, 0.2), right: (0.8, 0.8, 0.8)),
                                               key: "k", brightnessCap: 0.35)
        for color in palette.colors { XCTAssertLessThan(color.saturation, 0.25) }
    }

    func testWhiteImageIsCapped() {
        let palette = PaletteExtractor.palette(from: image(left: (1, 1, 1), right: (1, 1, 1)),
                                               key: "k", brightnessCap: 0.2)
        for color in palette.colors { XCTAssertLessThanOrEqual(color.brightness, 0.2 + 1e-9) }
    }

    func testFallbackIsDeterministicAndCapped() {
        let a = Palette.fallback(seed: "Some Album", cap: 0.3)
        XCTAssertEqual(a, Palette.fallback(seed: "Some Album", cap: 0.3))
        XCTAssertNotEqual(a, Palette.fallback(seed: "Other Album", cap: 0.3))
        XCTAssertEqual(a.colors.count, 4)
        for color in a.colors { XCTAssertLessThanOrEqual(color.brightness, 0.3 + 1e-9) }
    }
}
