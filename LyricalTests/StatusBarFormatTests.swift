//
//  StatusBarFormatTests.swift
//  LyricalTests
//

import XCTest
@testable import Lyrical

@MainActor
final class StatusBarFormatTests: XCTestCase {
    func testOffsetFormatting() {
        XCTAssertEqual(StatusBarController.formatOffset(0.25), "Timing: +0.25 s")
        XCTAssertEqual(StatusBarController.formatOffset(-0.5), "Timing: -0.50 s")
        XCTAssertEqual(StatusBarController.formatOffset(0), "Timing: +0.00 s")
    }

    func testNudgeRoundsAndClamps() {
        XCTAssertEqual(StatusBarController.nudged(0.25, by: 0.25), 0.5)
        XCTAssertEqual(StatusBarController.nudged(0.1 + 0.2, by: 0), 0.3)
        XCTAssertEqual(StatusBarController.nudged(9.9, by: 0.25), 10)
        XCTAssertEqual(StatusBarController.nudged(-9.9, by: -0.25), -10)
    }
}
