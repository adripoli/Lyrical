//
//  CarouselStyleTests.swift
//  LyricalTests
//

import XCTest
@testable import Lyrical

final class CarouselStyleTests: XCTestCase {

    func testOpacityFallsOffWithDistance() {
        XCTAssertEqual((0...5).map(CarouselStyle.opacity(distance:)), [1.0, 0.55, 0.38, 0.25, 0.15, 0.15])
        XCTAssertEqual(CarouselStyle.opacity(distance: CarouselStyle.renderRadius + 1), 0)
    }

    func testBlurTableAndSwitch() {
        XCTAssertEqual((0...4).map { CarouselStyle.blur(distance: $0, enabled: true) }, [0, 0, 1.2, 2.4, 3.6])
        XCTAssertEqual(CarouselStyle.blur(distance: 4, enabled: false), 0)
        XCTAssertEqual(CarouselStyle.blur(distance: CarouselStyle.renderRadius + 1, enabled: true), 0)
    }

    func testOnlyActiveLineIsFullScale() {
        XCTAssertEqual(CarouselStyle.scale(distance: 0), 1)
        XCTAssertEqual(CarouselStyle.scale(distance: 1), 0.86)
    }

    func testDistanceBeforeFirstLineCountsEveryLineOneFurther() {
        XCTAssertEqual(CarouselStyle.distance(of: 0, active: nil), 1)
        XCTAssertEqual(CarouselStyle.distance(of: 3, active: nil), 4)
        XCTAssertEqual(CarouselStyle.distance(of: 3, active: 5), 2)
    }

    func testOffsetCentersFocusLineOnAnchor() {
        let heights: [Int: CGFloat] = [0: 40, 1: 80]
        // Line 1 top = 40 + 10 spacing = 50; its middle = 90; 500 - 90 = 410.
        XCTAssertEqual(CarouselStyle.offset(focus: 1, heights: heights, estimate: 50, spacing: 10, anchorY: 500), 410)
        XCTAssertEqual(CarouselStyle.offset(focus: 0, heights: heights, estimate: 50, spacing: 10, anchorY: 500), 480)
    }

    func testOffsetUsesEstimateForUnmeasuredLines() {
        // Lines 0 and 1 unmeasured: (50 + 10) * 2 = 120 above line 2, whose middle is 120 + 25.
        XCTAssertEqual(CarouselStyle.offset(focus: 2, heights: [:], estimate: 50, spacing: 10, anchorY: 500), 355)
    }

    func testMetricsFromDefaults() {
        let metrics = CarouselMetrics(config: LyricalConfig(), screenSize: CGSize(width: 2000, height: 1000))
        XCTAssertEqual(metrics.fontSize, 45, accuracy: 0.001)
        XCTAssertEqual(metrics.columnWidth, 1200, accuracy: 0.001)
        XCTAssertEqual(metrics.anchorY, 450, accuracy: 0.001)
    }

    func testMetricsClampOutOfRangeConfig() {
        var config = LyricalConfig()
        config.fontSizeFraction = 5
        config.columnWidthFraction = -1
        config.anchorYFraction = 2
        let metrics = CarouselMetrics(config: config, screenSize: CGSize(width: 2000, height: 1000))
        XCTAssertEqual(metrics.fontSize, 120, accuracy: 0.001)     // 0.12 × 1000
        XCTAssertEqual(metrics.columnWidth, 400, accuracy: 0.001)  // 0.2 × 2000
        XCTAssertEqual(metrics.anchorY, 900, accuracy: 0.001)      // 0.9 × 1000
    }
}
