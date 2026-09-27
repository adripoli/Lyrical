//
//  ArtworkRendererTests.swift
//  LyricalTests
//
//  The backdrop is shared by the desktop and the lock screen, so it has to be
//  exactly the screen size, and the no-artwork gradient has to be the same for
//  an album on every launch.
//

import XCTest
@testable import Lyrical

final class ArtworkRendererTests: XCTestCase {

    func testFallbackColorsAreDeterministicPerSeed() {
        let a = ArtworkRenderer.fallbackColors(seed: "Blue")
        let b = ArtworkRenderer.fallbackColors(seed: "Blue")
        XCTAssertEqual(a.0, b.0)
        XCTAssertEqual(a.1, b.1)
        XCTAssertNotEqual(a.0, ArtworkRenderer.fallbackColors(seed: "Hounds of Love").0)
    }

    func testBlurredBackdropMatchesTheTargetSize() {
        let cover = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        let size = CGSize(width: 320, height: 200)

        let backdrop = ArtworkRenderer.blurred(cover, targetSize: size, blurRadius: 40, dim: 0.35)

        XCTAssertEqual(backdrop.size, size)
    }

    /// A 40pt blur holds no detail a 200px bitmap can't: the screen-sized
    /// upscale is left to the GPU, which does the same linear filtering the
    /// renderer used to do into a ~5 MB bitmap per screen.
    func testBackdropBitmapStaysAtTheWorkingSize() throws {
        let cover = NSImage(size: NSSize(width: 640, height: 640), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let size = CGSize(width: 1440, height: 900)

        let backdrop = ArtworkRenderer.blurred(cover, targetSize: size, blurRadius: 40, dim: 0.35)

        XCTAssertEqual(backdrop.size, size)
        let rep = try XCTUnwrap(backdrop.representations.first as? NSBitmapImageRep)
        XCTAssertLessThanOrEqual(rep.pixelsWide, 200)
        XCTAssertEqual(Double(rep.pixelsWide) / Double(rep.pixelsHigh), 1440.0 / 900, accuracy: 0.02)
    }

    func testDimDarkensTheBackdrop() throws {
        let cover = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let size = CGSize(width: 40, height: 40)

        let plain = try brightness(ArtworkRenderer.blurred(cover, targetSize: size, blurRadius: 10, dim: 0))
        let dimmed = try brightness(ArtworkRenderer.blurred(cover, targetSize: size, blurRadius: 10, dim: 0.5))

        XCTAssertLessThan(dimmed, plain - 0.2)
    }

    private func brightness(_ image: NSImage) throws -> CGFloat {
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        return try XCTUnwrap(color.usingColorSpace(.deviceRGB)).brightnessComponent
    }
}
