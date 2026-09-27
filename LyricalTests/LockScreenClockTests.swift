//
//  LockScreenClockTests.swift
//  LyricalTests
//
//  The lock-screen clock stands in for the system's, so it should read the same.
//

import XCTest
@testable import Lyrical

final class LockScreenClockTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: hour, minute: minute))!
    }

    func testTwelveHourHasNoLeadingZero() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(LockScreenClockView.time(date(18, 21), calendar: calendar, locale: us), "6:21")
        XCTAssertEqual(LockScreenClockView.time(date(6, 5), calendar: calendar, locale: us), "6:05")
    }

    func testTwelveHourMidnightAndNoonAreTwelve() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(LockScreenClockView.time(date(0, 0), calendar: calendar, locale: us), "12:00")
        XCTAssertEqual(LockScreenClockView.time(date(12, 30), calendar: calendar, locale: us), "12:30")
    }

    func testTwentyFourHourLocale() {
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(LockScreenClockView.time(date(18, 21), calendar: calendar, locale: de), "18:21")
        XCTAssertEqual(LockScreenClockView.time(date(0, 7), calendar: calendar, locale: de), "0:07")
    }

    func testGlyphShapeIsCentredInkOfTheDigits() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 200)
        let path = GlyphShape(text: "12:34", font: GlyphShape.fallbackFont(size: 160, design: .default)).path(in: rect)
        let ink = path.boundingRect
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(ink.midX, rect.midX, accuracy: 0.5)
        XCTAssertEqual(ink.midY, rect.midY, accuracy: 0.5)
        XCTAssertLessThan(ink.height, 160)
    }

    // The system clock faces live in a private font collection; these checks
    // pin that we find the face loginwindow would use for each setting.

    private func name(_ font: CTFont?) -> String? {
        font.map { CTFontCopyPostScriptName($0) as String }
    }

    private func weight(_ font: CTFont) -> Double? {
        let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
        return variation?[NSNumber(value: 0x7767_6874)]?.doubleValue
    }

    func testEveryClockSettingResolvesToItsFace() throws {
        for (identifier, family) in SystemClockFont.families {
            let font = SystemClockFont.font(identifier: identifier, weight: nil, size: 100)
            XCTAssertEqual(name(font).map { $0.hasPrefix(family) }, true, identifier)
        }
    }

    func testUnsetOrUnknownIdentifierUsesTheDefaultFace() {
        let font = SystemClockFont.font(identifier: "nonsense", weight: nil, size: 100)
        XCTAssertEqual(name(font).map { $0.hasPrefix(".SFAdaptiveSoftNumeric") }, true)
        XCTAssertEqual(name(SystemClockFont.font(identifier: nil, weight: nil, size: 100)), name(font))
    }

    func testWeightFollowsTheSystemScaleOnSFFaces() throws {
        let heavy = try XCTUnwrap(SystemClockFont.font(identifier: "soft", weight: 800, size: 100))
        XCTAssertEqual(try XCTUnwrap(weight(heavy)), 800, accuracy: 0.5)
    }

    func testWeightMapsOntoEachFacesOwnNamedInstances() throws {
        // Rail's axis runs 1–400 with its Regular at 200.5, so the system's
        // 400 must land on Rail Regular, not on its heaviest end.
        XCTAssertEqual(try XCTUnwrap(SystemClockFont.axisCoordinate(forWeight: 400, family: ".SFRailNumeric")),
                       200.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(SystemClockFont.axisCoordinate(forWeight: 700, family: ".SFRailNumeric")),
                       300.25, accuracy: 0.01)
        // Past Black clamps to the face's heaviest.
        XCTAssertEqual(try XCTUnwrap(SystemClockFont.axisCoordinate(forWeight: 5000, family: ".SFRailNumeric")),
                       400, accuracy: 0.01)
    }

    func testClockFaceDrawsTheTime() throws {
        let font = try XCTUnwrap(SystemClockFont.font(identifier: "rail", weight: 400, size: 160))
        let path = GlyphShape(text: "12:34", font: font).path(in: CGRect(x: 0, y: 0, width: 1000, height: 200))
        XCTAssertFalse(path.isEmpty)
        XCTAssertLessThan(path.boundingRect.height, 160)
    }
}
