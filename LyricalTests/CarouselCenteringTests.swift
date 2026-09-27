//
//  CarouselCenteringTests.swift
//  LyricalTests
//
//  Centred lyrics must sit on the screen's centre line, whichever way a line
//  is drawn: plain, word-timed, lit or not.
//

import SwiftUI
import XCTest
@testable import Lyrical

@MainActor
final class CarouselCenteringTests: XCTestCase {
    private let screen = CGSize(width: 1440, height: 900)

    private func words(_ text: String) -> [LyricWord] {
        let parts = text.split(separator: " ")
        return parts.enumerated().map { index, word in
            let trailing = index == parts.count - 1 ? "" : " "
            return LyricWord(text: word + trailing, start: Double(index), end: Double(index) + 0.9)
        }
    }

    private func inkCenterX(_ lines: [LyricLine], active: Int?, animateWords: Bool) throws -> CGFloat {
        try inkBounds(lines, active: active, animateWords: animateWords).midX
    }

    /// Horizontal extent of the solid (non-shadow) pixels, in points.
    private func inkBounds(_ lines: [LyricLine], active: Int?, animateWords: Bool,
                           alignment: TextAlignmentOption = .center) throws -> (minX: CGFloat, midX: CGFloat) {
        var config = LyricalConfig()
        config.textAlignment = alignment
        config.animateWords = animateWords
        config.blurInactive = false
        let metrics = CarouselMetrics(config: config, screenSize: screen)
        let view = LyricsCarouselView(lines: lines, activeIndex: active, move: .jump, isPlaying: false,
                                      metrics: metrics, position: { 0.5 })
            .frame(width: screen.width, height: screen.height, alignment: .top)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 100 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, 0, "nothing was drawn")
        return (CGFloat(minX), CGFloat(minX + maxX + 1) / 2)
    }

    /// Paused before any word starts, so nothing swells.
    private func unsung(_ text: String, trailingSpaces: Bool = false) -> LyricLine {
        LyricLine(time: 0, text: text, isGap: false, words: words(text).map {
            LyricWord(text: trailingSpaces ? $0.text.trimmingCharacters(in: .whitespaces) + " " : $0.text,
                      start: $0.start + 100, end: $0.end + 100)
        })
    }

    private let text = "We're still the kids we used to be, yeah, yeah"

    func testPlainLineIsCentered() throws {
        let x = try inkCenterX([LyricLine(time: 0, text: text, isGap: false)], active: 0, animateWords: false)
        XCTAssertEqual(x, screen.width / 2, accuracy: 4)
    }

    func testWordTimedUnlitLineIsCentered() throws {
        let lines = [LyricLine(time: 0, text: text, isGap: false, words: words(text)),
                     LyricLine(time: 99, text: "later", isGap: false)]
        // Line 0 isn't lit (nothing is before the first line), so it draws plainly through the renderer.
        let x = try inkCenterX(Array(lines.prefix(1)), active: nil, animateWords: true)
        XCTAssertEqual(x, screen.width / 2, accuracy: 4)
    }

    func testWordTimedLitLineIsCentered() throws {
        let x = try inkCenterX([unsung(text)], active: 0, animateWords: true)
        XCTAssertEqual(x, screen.width / 2, accuracy: 4)
    }

    func testWordTimedLineWithTrailingSpaceIsCentered() throws {
        let x = try inkCenterX([unsung(text, trailingSpaces: true)], active: 0, animateWords: true)
        XCTAssertEqual(x, screen.width / 2, accuracy: 8)
    }

    func testWrappedWordTimedLineIsCentered() throws {
        let long = "Yeah, and nothing hurts anymore, I feel kinda free, we're still the kids we used to be"
        let plain = try inkCenterX([LyricLine(time: 0, text: long, isGap: false)], active: 0, animateWords: false)
        let timed = try inkCenterX([unsung(long)], active: 0, animateWords: true)
        XCTAssertEqual(timed, plain, accuracy: 2)
        XCTAssertEqual(timed, screen.width / 2, accuracy: 4)
    }

    func testLeadingAlignedWordTimedLineStartsWithPlainText() throws {
        let plain = try inkBounds([LyricLine(time: 0, text: text, isGap: false)], active: 0,
                                  animateWords: false, alignment: .leading)
        let timed = try inkBounds([unsung(text)], active: 0, animateWords: true, alignment: .leading)
        XCTAssertEqual(timed.minX, plain.minX, accuracy: 2)
    }

    func testLineWithoutWordTimingIsCenteredWhenAnimating() throws {
        let x = try inkCenterX([LyricLine(time: 0, text: text, isGap: false)], active: 0, animateWords: true)
        XCTAssertEqual(x, screen.width / 2, accuracy: 4)
    }
}
